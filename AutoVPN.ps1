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

    
    Automates OpenVPN connection based on Windows Network Category (Public vs Private)

#>

# --- PARAMETERS ---
param (
    [string]$Trigger = "Manual"
)

# --- CONFIGURATION ---
$OpenVPNPath = "C:\Program Files\OpenVPN\bin\openvpn-gui.exe"
$OvnConfigName = "openvpn.pretty-private.ovpn" # CHANGE THIS to your actual config name
$LogFile = "$PSScriptRoot\AutoVPN.log"
$EventSource = "OpenVPN-AutoVPN"
$TrustedSpecificSSIDs = @("MySecretHomeWiFi") # Optional: specific SSIDs to always trust even if Public

# --- FUNCTIONS ---
function Get-TriggerReason {
    param ($TriggerCode)
    
    switch -Regex ($TriggerCode) {
        "^Event-10000$" { return "Network Connected" }
        "^Event-1$" { return "System Wake" }
        "^Event-7036$" { return "OpenVPN Service Started" }
        "^Logon$" { return "User Logon" }
        "^Manual$" { return "Manual Execution" }
        Default { return $TriggerCode }
    }
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "Information"
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] [$Level] $Message"

    # 1. Try writing to Event Log
    try {
        # Check if source exists, if not, we can't create it as non-admin, so this might fail first time
        # but we try to write using 'Application' log if source registration fails?
        # Actually, Write-EventLog requires source to exist.
        if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            Write-EventLog -LogName "Application" -Source $EventSource -EntryType $Level -EventId 100 -Message $Message
        }
    }
    catch {
        # Silent fail on Event Log for non-admins
    }

    # 2. Always write to text file as fallback/primary for user
    try {
        $LogEntry | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
    catch {
        Write-Host "Error writing to log file: $_"
    }
    
    Write-Host $LogEntry
}

function Get-VPNStatus {
    # Check if OpenVPN is connected. 
    # Method A: Check for TAP/TUN adapter with IP.
    # Method B: Check if specific route exists.
    # Method C: Simple check if the OpenVPN GUI has a connection process? 
    # Let's use simple interface check.
    
    $vpnInterface = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*TAP-Windows*" -or $_.InterfaceDescription -like "*OpenVPN*" } | Where-Object { $_.Status -eq "Up" }
    return ($null -ne $vpnInterface)
}

function Manage-VPN {
    $Profiles = Get-NetConnectionProfile
    $NeedsVPN = $false
    $Reason = ""

    # Filter out the VPN interface itself from the profile check to avoid loops
    # VPN interfaces often show as 'Unidentified' or 'Public'
    $PhysicalProfiles = $Profiles | Where-Object { $_.InterfaceAlias -notlike "*VPN*" -and $_.InterfaceDescription -notlike "*TAP*" -and $_.InterfaceDescription -notlike "*OpenVPN*" }

    if (-not $PhysicalProfiles) {
        Write-Log "No active physical network connection found." "Warning"
        return $false # Retry needed
    }

    foreach ($p in $PhysicalProfiles) {
        if ($p.NetworkCategory -eq "Public") {
            # Check exceptions
            if ($p.Name -in $TrustedSpecificSSIDs) {
                Write-Log "Network [$($p.Name)] is Public but in Trusted List. Treating as Trusted and will not connect to VPN."
            }
            else {
                $NeedsVPN = $true
                $Reason = "Network [$($p.Name)] in network category $($p.NetworkCategory) is not a Trusted network."
                break # Found one unsafe network, so we need VPN
            }
        }
    }

    $IsConnected = Get-VPNStatus

    if ($NeedsVPN) {
        if (-not $IsConnected) {
            Write-Log "ACTION: Connecting VPN. Reason: $Reason"
            # Start OpenVPN
            # --command connect requires the config file to be in the config dir
            Start-Process -FilePath $OpenVPNPath -ArgumentList "--command connect `"$OvnConfigName`"" -WindowStyle Hidden
            return $false # Verify next loop
        }
        else {
            Write-Log "VPN is already connected on untrusted network [$($p.Name)]."
            return $true # Compliant
        }
    }
    else {
        # We are on Trusted networks
        if ($IsConnected) {
            Write-Log "ACTION: Disconnecting VPN. Reason: All active networks are Trusted (Private/Domain)."
            Start-Process -FilePath $OpenVPNPath -ArgumentList "--command disconnect `"$OvnConfigName`"" -WindowStyle Hidden
            return $false # Verify next loop
        }
        else {
            Write-Log "Safe on trusted network [$($p.Name)]. VPN is disconnected."
            return $true # Compliant
        }
    }
}

# --- MAIN ---
$MutexName = "Global\OpenVPN-AutoVPN-Instance"
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)

# Try to acquire the mutex (wait 0ms)
if (-not $Mutex.WaitOne(0, $false)) {
    # Could not acquire mutex, meaning another instance is running
    # We might want to log this to a separate file or just exit silently/quietly to avoid log spam
    # But user asked for it, so let's log it.
    
    # We can't use Write-Log nicely if we want to be super fast, but we have the function.
    # Let's just use Write-Log.
    # Note: If multiple triggers happen instantly, log might get messy, but mutex protects the logic.
    Write-Log "Skipped: Another instance is already running [Trigger: $Trigger]" "Warning"
    exit
}

try {
    $ReasonReadable = Get-TriggerReason $Trigger
    Write-Log "--- AutoVPN Check Started [Trigger: $ReasonReadable] ---"

    # We will loop for a certain period (e.g., 2 minutes) to catch delayed startups of OpenVPN or Wifi
    # 12 checks * 10 seconds = 120 seconds
    $MaxRetries = 12
    $RetryInterval = 10

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            Write-Log "Check cycle $($i + 1)/$MaxRetries..."
            $IsStable = Manage-VPN
        
            if ($IsStable) {
                Write-Log "State is compliant. Stopping checks."
                break
            }
        }
        catch {
            Write-Log "Critical Error: $_" "Error"
        }

        # If we are at the last iteration, don't sleep
        if ($i -lt ($MaxRetries - 1)) {
            Start-Sleep -Seconds $RetryInterval
        }
    }

    Write-Log "--- AutoVPN Check Finished ---"
}
finally {
    if ($Mutex) {
        $Mutex.ReleaseMutex()
        $Mutex.Dispose()
    }
}
