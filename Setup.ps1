<#
    Copyright (c) 2026 bastbnl

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software, to deal in the Software without restriction, including without 
    limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, 
    and/or sell copies of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.
#>
# Install-Task.ps1
# Registers the AutoVPN task in Windows Task Scheduler
# Usage:
#   .\Install-Task.ps1                     -> Registers the task (Run as User)
#   .\Install-Task.ps1 -CreateEventSource  -> Creates Event Log Source (Run as Admin once)

param (
  [switch]$CreateEventSource
)

$TaskName = "OpenVPN-AutoVPN"
$EventSource = "OpenVPN-AutoVPN"
$ScriptPath = "$PSScriptRoot\AutoVPN.ps1"
$PowershellPath = (Get-Command powershell).Source

if ($CreateEventSource) {
  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "To create the Event Source, you must run this script as Administrator."
    exit
  }
    
  if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    Write-Host "Event Source '$EventSource' already exists."
  }
  else {
    New-EventLog -LogName Application -Source $EventSource
    Write-Host "Event Source '$EventSource' created successfully."
  }
  exit
}

Write-Host "Registering Task: $TaskName"
Write-Host "Script Path: $ScriptPath"

# 1. Remove existing task if any
try {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed existing task."
}
catch {}

# 2. Define Triggers
# Trigger on Network Connect (ID 10000)
$TriggerConnect = New-ScheduledTaskTrigger -AtLogOn
# Note: Complex XML event triggers are hard to do with New-ScheduledTaskTrigger alone in basic PS.
# We will use a standard "AtLogOn" trigger and "Repetition" for simplicity if Event fails, 
# BUT standard users can use Event Triggers via XML.
# Let's try attempting to add a simple AtLogon trigger first to ensure it runs.
# Ideally, we want real event triggers.
# The best way for non-admin to get event triggers is "On an Event".

# We will create the task with a Logon trigger first, then we might need to rely on the user manually importing an XML
# OR we try to construct the object.
# Actually, New-ScheduledTaskTrigger doesn't support Event.
# We have to use *New-ScheduledTask* locally.

$Action = New-ScheduledTaskAction -Execute $PowershellPath -Argument "-WindowStyle Hidden -File `"$ScriptPath`""

# We want it to run when network changes.
# If we can't easily script the Event Trigger in pure PS without Admin (some modules needed?),
# we will provide an XML file and use Register-ScheduledTask -Xml.
# That is robust.

$TaskXML = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2023-10-25T14:46:00</Date>
    <Author>$env:USERNAME</Author>
    <Description>AutoVPN Automation</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000 or EventID=10002)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$PowershellPath</Command>
      <Arguments>-WindowStyle Hidden -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$XmlPath = "$PSScriptRoot\AutoVPN_Task.xml"
$TaskXML | Out-File -FilePath $XmlPath -Encoding Unicode

try {
  Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content $XmlPath -Raw) -Force
  Write-Host "SUCCESS: Task '$TaskName' registered successfully."
  Write-Host "It will run on LogOn and when Network Connects/Disconnects."
}
catch {
  Write-Host "ERROR: Could not register task."
  Write-Host $_
}
