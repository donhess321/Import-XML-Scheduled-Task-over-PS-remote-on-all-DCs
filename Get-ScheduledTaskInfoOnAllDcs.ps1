<# 
.SYNOPSIS 
    Get the task schedule information for each DC to a CSV file
.EXAMPLE 
    PS Get-ScheduledTaskInfoOnAllDcs.ps1 'mycsvfile.csv'
.NOTES 
	Author: Originally (90%) from Get-ScheduledTask.ps1 by Bill Stewart (bstewart@iname.com)
    Version History:
    1.0    2016-07-06   Release
#>
Param(
    [Parameter(Mandatory=$true,
			   ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=0,
			   HelpMessage='Full path of CSV output file')]
    [ValidateNotNullOrEmpty()]
    [Alias('Path')]
    [string] $CsvFile,

    [Parameter(Mandatory=$false,
			   ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=1,
			   HelpMessage='PS remoting credential object')]
    [System.Management.Automation.PSCredential] $Cred
)

$scriptBlock1 = [System.Management.Automation.ScriptBlock]::Create(@'
function fGet-ScheduledTask(
  [parameter(Position=0)] [String[]] $TaskName="*",
  [parameter(Position=1,ValueFromPipeline=$TRUE)] [String[]] $ComputerName=$ENV:COMPUTERNAME,
  [switch] $Subfolders,
  [switch] $Hidden,
  [System.Management.Automation.PSCredential] $ConnectionCredential
  ) {
    begin {
      $PIPELINEINPUT = (-not $PSBOUNDPARAMETERS.ContainsKey("ComputerName")) -and (-not $ComputerName)
      $MIN_SCHEDULER_VERSION = "1.2"
      $TASK_ENUM_HIDDEN = 1
      $TASK_STATE = @{0 = "Unknown"; 1 = "Disabled"; 2 = "Queued"; 3 = "Ready"; 4 = "Running"}
      $ACTION_TYPE = @{0 = "Execute"; 5 = "COMhandler"; 6 = "Email"; 7 = "ShowMessage"}

      # Try to create the TaskService object on the local computer; throw an error on failure
      try {
        $TaskService = new-object -comobject "Schedule.Service"
      }
      catch [System.Management.Automation.PSArgumentException] {
        throw $_
      }

      # Returns the specified PSCredential object's password as a plain-text string
      function get-plaintextpwd($credential) {
        $credential.GetNetworkCredential().Password
      }

      # Returns a version number as a string (x.y); e.g. 65537 (10001 hex) returns "1.1"
      function convertto-versionstr([Int] $version) {
        $major = [Math]::Truncate($version / [Math]::Pow(2, 0x10)) -band 0xFFFF
        $minor = $version -band 0xFFFF
        "$($major).$($minor)"
      }

      # Returns a string "x.y" as a version number; e.g., "1.3" returns 65539 (10003 hex)
      function convertto-versionint([String] $version) {
        $parts = $version.Split(".")
        $major = [Int] $parts[0] * [Math]::Pow(2, 0x10)
        $major -bor [Int] $parts[1]
      }

      # Returns a list of all tasks starting at the specified task folder
      function get-task($taskFolder) {
        $tasks = $taskFolder.GetTasks($Hidden.IsPresent -as [Int])
        $tasks | foreach-object { $_ }
        if ($SubFolders) {
          try {
            $taskFolders = $taskFolder.GetFolders(0)
            $taskFolders | foreach-object { get-task $_ $TRUE }
          }
          catch [System.Management.Automation.MethodInvocationException] {
          }
        }
      }

      # Returns a date if greater than 12/30/1899 00:00; otherwise, returns nothing
      function get-OLEdate($date) {
        if ($date -gt [DateTime] "12/30/1899") { $date }
      }

      function get-scheduledtask2($computerName) {
        # Assume $NULL for the schedule service connection parameters unless -ConnectionCredential used
        $userName = $domainName = $connectPwd = $NULL
        if ($ConnectionCredential) {
          # Get user name, domain name, and plain-text copy of password from PSCredential object
          $userName = $ConnectionCredential.UserName.Split("\")[1]
          $domainName = $ConnectionCredential.UserName.Split("\")[0]
          $connectPwd = get-plaintextpwd $ConnectionCredential
        }
        try {
          $TaskService.Connect($ComputerName, $userName, $domainName, $connectPwd)
        }
        catch [System.Management.Automation.MethodInvocationException] {
          write-warning "$computerName - $_"
          return
        }
        $serviceVersion = convertto-versionstr $TaskService.HighestVersion
        $vistaOrNewer = (convertto-versionint $serviceVersion) -ge (convertto-versionint $MIN_SCHEDULER_VERSION)
        $rootFolder = $TaskService.GetFolder("\")
        $taskList = get-task $rootFolder
        if (-not $taskList) { return }
        foreach ($task in $taskList) {
          foreach ($name in $TaskName) {
            # Assume root tasks folder (\) if task folders supported
            if ($vistaOrNewer) {
              if (-not $name.Contains("\")) { $name = "\$name" }
            }
            if ($task.Path -notlike $name) { continue }
            $taskDefinition = $task.Definition
            $actionCount = 0
            foreach ($action in $taskDefinition.Actions) {
              $actionCount += 1
              $output = new-object PSObject
              # PROPERTY: ComputerName
              $output | add-member NoteProperty ComputerName $computerName
              # PROPERTY: ServiceVersion
              $output | add-member NoteProperty ServiceVersion $serviceVersion
              # PROPERTY: TaskName
              if ($vistaOrNewer) {
                $output | add-member NoteProperty TaskName $task.Path
              } else {
                $output | add-member NoteProperty TaskName $task.Name
              }
              #PROPERTY: Enabled
              $output | add-member NoteProperty Enabled ([Boolean] $task.Enabled)
              # PROPERTY: ActionNumber
              $output | add-member NoteProperty ActionNumber $actionCount
              # PROPERTIES: ActionType and Action
              # Old platforms return null for the Type property
              if ((-not $action.Type) -or ($action.Type -eq 0)) {
                $output | add-member NoteProperty ActionType $ACTION_TYPE[0]
                $output | add-member NoteProperty Action "$($action.Path) $($action.Arguments)"
              } else {
                $output | add-member NoteProperty ActionType $ACTION_TYPE[$action.Type]
                $output | add-member NoteProperty Action $NULL
              }
              # PROPERTY: LastRunTime
              $output | add-member NoteProperty LastRunTime (get-OLEdate $task.LastRunTime)
              # PROPERTY: LastResult
              if ($task.LastTaskResult) {
                # If negative, convert to DWORD (UInt32)
                if ($task.LastTaskResult -lt 0) {
                  $lastTaskResult = "0x{0:X}" -f [UInt32] ($task.LastTaskResult + [Math]::Pow(2, 32))
                } else {
                  $lastTaskResult = "0x{0:X}" -f $task.LastTaskResult
                }
              } else {
                $lastTaskResult = $NULL  # fix bug in v1.0-1.1 (should output $NULL)
              }
              $output | add-member NoteProperty LastResult $lastTaskResult
              # PROPERTY: NextRunTime
              $output | add-member NoteProperty NextRunTime (get-OLEdate $task.NextRunTime)
              # PROPERTY: State
              if ($task.State) {
                $taskState = $TASK_STATE[$task.State]
              }
              $output | add-member NoteProperty State $taskState
              $regInfo = $taskDefinition.RegistrationInfo
              # PROPERTY: Author
              $output | add-member NoteProperty Author $regInfo.Author
              # The RegistrationInfo object's Date property, if set, is a string
              if ($regInfo.Date) {
                $creationDate = [DateTime]::Parse($regInfo.Date)
              }
              $output | add-member NoteProperty Created $creationDate
              # PROPERTY: RunAs
              $principal = $taskDefinition.Principal
              $output | add-member NoteProperty RunAs $principal.UserId
              # PROPERTY: Elevated
              if ($vistaOrNewer) {
                if ($principal.RunLevel -eq 1) { $elevated = $TRUE } else { $elevated = $FALSE }
              }
              $output | add-member NoteProperty Elevated $elevated
              # Output the object
              $output
            }
          }
        }
      }
    }

    process {
      if ($PIPELINEINPUT) {
        get-scheduledtask2 $_
      }
      else {
        $ComputerName | foreach-object {
          get-scheduledtask2 $_
        }
      }
    }
}
fGet-ScheduledTask
'@) # End scriptblock1
if ($null -eq $Cred) {
	$Cred = Get-Credential
}
Import-Module ActiveDirectory
$aResults = @()
# Get all DC as they have the scheduled task)
$aDcs = Get-ADDomainController -Filter * | Select -Expand Name | Sort
$aDcs | ForEach-Object {
	$sDcName = $_
	Write-Host "Working on $sDcName"
	try {
		$sessionSrv1 = New-PSSession -ComputerName $sDcName -Credential $Cred -ErrorAction Stop
		Write-Host "  Session created for $sDcName"
		$oSingeResult = (Invoke-Command -Session $sessionSrv1 -ScriptBlock $scriptBlock1 -ErrorAction Stop)
		Write-Host "  Results returned for $sDcName"
		$aResults += $oSingeResult
	}
	catch { # Just set up a dummy object so the user sees something didn't work
		$err = $_
		$textOut = "  Error while on $sDcName " + $err.Exception.Message.ToString()
        Write-Host $textOut
    }
	Remove-PSSession $sessionSrv1 -ErrorAction SilentlyContinue
}
$aResults | Export-Csv -Path $CsvFile
