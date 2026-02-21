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


    Registers the AutoVPN task in Windows Task Scheduler
    Usage:
    .\Setup.ps1                     -> Registers the task (Run as User)
    .\Setup.ps1 -CreateEventSource  -> Creates Event Log Source (Run as Admin once)
    .\Setup.ps1 -TargetUser "User"  -> Registers the task for a specific user (Run as Admin)
    .\Setup.ps1 -Remove             -> Removes the scheduled task


#>


param (
  [switch]$CreateEventSource,
  [string]$TargetUser,
  [switch]$Remove
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EventSource = "OpenVPN-AutoVPN"
$TaskName = $EventSource
$ScriptPath = "$PSScriptRoot\AutoVPN.ps1"
$PowershellPath = (Get-Command powershell).Source

if ($CreateEventSource) {
  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "To create the Event Source, you must run this script as Administrator."
    exit
  }
    
  if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    Write-Host "$([char]0x2705) EventSource [$EventSource] exists and was not touched."
  }
  else {
    New-EventLog -LogName Application -Source $EventSource
    Write-Host "$([char]0x2705) EventSource [$EventSource] created successfully." -ForegroundColor Green
  }
  exit
}

Write-Host "Script Path: $ScriptPath"

# 1. Remove existing tasks
$OldTasks = @($TaskName, "$TaskName-Logon", "$TaskName-Event")
foreach ($T in $OldTasks) {
  try {
    Unregister-ScheduledTask -TaskName $T -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "$([char]0x2705) Removed existing task [$T]." -ForegroundColor Green
  }
  catch {
    # Ignore errors if task doesn't exist
  }
}

if ($Remove) {
  Write-Host "Task removal requested. Exiting."
  exit
}

# 2. Prepare User Account
if ($TargetUser) {
  try {
    $objUser = New-Object System.Security.Principal.NTAccount($TargetUser)
    $sid = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
    Write-Host "Targeting User Account: $TargetUser (SID: $sid)" -ForegroundColor Cyan
    $UserAccount = $TargetUser
  }
  catch {
    Write-Error "User '$TargetUser' not found on this system!"
    exit
  }
}
else {
  $UserAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  Write-Host "Targeting Current User: $UserAccount"
}

# 3. Create XMLs for Tasks

# --- TASK A: LOGON TRIGGER ---
# Simple Logon trigger that passes "-Trigger Logon"
$TaskXmlLogon = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2023-10-25T14:46:00</Date>
    <Author>$UserAccount</Author>
    <Description>AutoVPN Automation - Logon Trigger</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$UserAccount</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
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
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$PowershellPath</Command>
      <Arguments>-ExecutionPolicy Bypass -File "$ScriptPath" -Trigger Logon -WindowStyle Hidden</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# --- TASK B: EVENT TRIGGER ---
# Event trigger that passes "-Trigger Event-$(eventID)" using ValueQueries
$TaskXmlEvent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2023-10-25T14:46:00</Date>
    <Author>$UserAccount</Author>
    <Description>AutoVPN Automation - Event Trigger</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000 or EventID=10002)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries>
        <Value name="eventId">Event/System/EventID</Value>
      </ValueQueries>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries>
        <Value name="eventId">Event/System/EventID</Value>
      </ValueQueries>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Service Control Manager'] and (EventID=7036)]] and *[EventData[Data[@Name='param1']='SERVICE_NAAM' and Data[@Name='param2']='running']]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries>
        <Value name="eventId">Event/System/EventID</Value>
      </ValueQueries>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$UserAccount</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
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
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$PowershellPath</Command>
      <Arguments>-ExecutionPolicy Bypass -File "$ScriptPath" -Trigger Event-`$(eventId) -WindowStyle Hidden</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# Helper to save and register
function Register-MyTask {
  param($Name, $XmlContent)
  $XmlPath = "$PSScriptRoot\${Name}.xml"
  $XmlContent | Out-File -FilePath $XmlPath -Encoding Unicode
    
  try {
    Register-ScheduledTask -TaskName $Name -Xml (Get-Content $XmlPath -Raw) -Force -ErrorAction Stop | Out-Null
    Write-Host "$([char]0x2705) Task [$Name] registered successfully." -ForegroundColor Green
    return $true
  }
  catch {
    Write-Host "$([char]0x274C) Could not register task [$Name]. Error: $_" -ForegroundColor Red
    return $false
  }
  finally {
    # Clean up temp xml
    Remove-Item $XmlPath -ErrorAction SilentlyContinue
  }
}

$SuccessLogon = Register-MyTask -Name "$TaskName-Logon" -XmlContent $TaskXmlLogon
$SuccessEvent = Register-MyTask -Name "$TaskName-Event" -XmlContent $TaskXmlEvent

if ($SuccessLogon -and $SuccessEvent) {
  Write-Host "$([char]0x2705) Setup Complete!" -ForegroundColor Green
  Write-Host "Please check Task Scheduler to verify '$TaskName-Logon' and '$TaskName-Event' are present."
}
else {
  Write-Host "$([char]0x274C) Setup Failed for one or more tasks." -ForegroundColor Red
  Write-Host "Please run this script as Administrator to ensure tasks can be registered."
}

exit
