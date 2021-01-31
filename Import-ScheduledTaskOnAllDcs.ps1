<# 
.SYNOPSIS 
    Using remoting, import the specified task from XML file for each DC.
    $PsCred and $TaskCred parameters are optional.  You will be asked for 
    them if not passed during runtime.
.EXAMPLE 
    Edit script to load all the XML files, then:
    PS Import-ScheduledTaskOnAllDcs.ps1 $PsCred $TaskCred
.NOTES 
    Designed for Win 2008+, Requires PS2+
    Author: Don Hess
    Version History:
    1.0    2016-07-24   Release
#>
Param(
    [Parameter(Mandatory=$false,
			   ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=0,
			   HelpMessage='PS remoting credential object')]
    [System.Management.Automation.PSCredential] $PsCred,
    [Parameter(Mandatory=$false,
			   ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=1,
			   HelpMessage="The task's credentials to run as")]
    [System.Management.Automation.PSCredential] $TaskCred
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version latest -Verbose

if ($null -eq $PsCred) {
	$PsCred = Get-Credential -Message 'Input PS Remoting credentials'
}
if ($null -eq $TaskCred) {
	$TaskCred = Get-Credential -Message "Input the task's credentials to run as"
}
function Create-TaskObjectStore([array[]] $aInfo) {
    $oReturned = New-Object -TypeName System.Management.Automation.PSObject
    Add-Member -InputObject $oReturned -MemberType NoteProperty -Name TaskCred -Value $aInfo[0]
    Add-Member -InputObject $oReturned -MemberType NoteProperty -Name TaskName -Value $aInfo[1]
    Add-Member -InputObject $oReturned -MemberType NoteProperty -Name XmlFilePath -Value ('FileSystem::'+$aInfo[2])  # Fixes UNC paths
    Add-Member -InputObject $oReturned -MemberType NoteProperty -Name XmlFileContents -Value (Get-Content -Raw -Path $oReturned.XmlFilePath)
    $oReturned
}
######## Enter all your tasks to import here ########
$aTasksToImport = @()

$sName = 'DNS_Cache_Logging_to_SQL'
$sXmlFile = '\\server\it\DNS to SQL\DNS_Cache_Logging_to_SQL.xml'
$oSingleTask = Create-TaskObjectStore @($TaskCred,$sName,$sXmlFile)
$aTasksToImport += $oSingleTask

$sName = 'DNS_Query_Logging_to_SQL'
$sXmlFile = '\\server\it\DNS to SQL\DNS_Query_Logging_to_SQL.xml'
$oSingleTask = Create-TaskObjectStore @($TaskCred,$sName,$sXmlFile)
$aTasksToImport += $oSingleTask
######## Tasks to import end ########

$scriptBlock1 = {
    # This is run on the remote machine
    # $oSingleTask must contain everthing needed on the remote machine
    param ($oSingleTask)
    # Remove existing task with same name.  Our task should be in the root folder by default
    $TaskService = New-Object -ComObject "Schedule.Service"
    $TaskService.Connect('localhost')
    $rootFolder = $TaskService.GetFolder("\")
    $tasks = $rootFolder.GetTasks(1)
    # Must use foreach on ComObject.  Cannot be a PS array
    foreach ($task in $tasks) {
        if ($task.Name -eq $oSingleTask.TaskName) {
            $rootFolder.DeleteTask($task.Name,0)
        }
    }
    # Output the XML file so schtasks can import it
    $sXmlTempFile = $env:TEMP+'\'+$oSingleTask.TaskName+'.xml'
    Out-File -Force -Encoding unicode -FilePath $sXmlTempFile -InputObject $oSingleTask.XmlFileContents
    $sTaskName = $oSingleTask.TaskName
    & schtasks /create /tn "$sTaskName" /xml "$sXmlTempFile" /ru $oSingleTask.TaskCred.Username /rp $oSingleTask.TaskCred.GetNetworkCredential().Password
} # End scriptblock1

Import-Module ActiveDirectory
# Get all DCs
$aDcs = Get-ADDomainController -Filter * | Select -Expand Name | Sort
$aDcs | ForEach-Object {
	$sDcName = $_
	Write-Host "Working on $sDcName"
	try {
		$sessionSrv1 = New-PSSession -ComputerName $sDcName -Credential $PsCred -ErrorAction Stop
		Write-Host "  Session created for $sDcName"

        $aTasksToImport | ForEach-Object {
            $oSingleTask = $_
            # For Win 2008
			Invoke-Command -Session $sessionSrv1 -ScriptBlock $scriptBlock1 -ArgumentList $oSingleTask
            
            # Win 2012 (still needs to be worked on)
            # This will create the scheduled task in the root task folder.  -Force overwrites the task that has the same name
            # Register-ScheduledTask –Force -Xml (get-content '\\chi-fp01\it\Weekly System Info Report.xml' | out-string) -TaskName "Weekly System Info Report" -User globomantics\administrator -Password P@ssw0rd 
	        #$oSingeResult = (Invoke-Command -Session $sessionSrv1 -ScriptBlock {`
			#	Register-ScheduledTask –Force -Xml ${sXmlContent} -TaskName ${oSingleTask.TaskName} -User ${oSingleTask.Username} -Password ${oSingleTask.Password} `
			#} -ErrorAction Stop)
			#Register-ScheduledTask –Force -Xml ${sXmlContent} -TaskName ${oSingleTask.TaskName} -User ${oSingleTask.Username} -Password ${oSingleTask.Password}
        } # End $aTasksToImport | ForEach-Object {
	}
	catch {
		$err = $_
        $textOut = "  Error while on $sDcName " + $err.Exception.Message.ToString()
        Write-Host $textOut
    }
	Remove-PSSession $sessionSrv1 -ErrorAction SilentlyContinue
}




