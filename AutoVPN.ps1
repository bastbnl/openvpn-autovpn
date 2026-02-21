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

# --- GLOBALS ---
$script:ActionTakenCount = 0

# --- FUNCTIONS ---
function Test-IsVPNAdapter {
    param([PSObject]$Adapter)
    # This script is strictly for OpenVPN/TAP management. 
    # Other VPNs (WireGuard, Tailscale) are ignored by the management logic.
    $Desc = $Adapter.InterfaceDescription
    return ($Desc -like "*TAP-Windows*" -or 
            $Desc -like "*OpenVPN*")
}

function Test-IsPhysicalAdapter {
    param([PSObject]$Adapter)
    
    # 1. VPNs are never physical adapters for our logic
    if (Test-IsVPNAdapter $Adapter) {
        return $false
    }

    $Desc = $Adapter.InterfaceDescription

    # 2. Broad exclusion of virtual/software/known noise
    # We use very specific substrings to avoid catching real hardware.
    # We include other VPN types here (WireGuard, Wintun) to ensure they are never physical.
    if ($Desc -like "*Virtual*" -or 
        $Desc -like "*Bluetooth*" -or 
        $Desc -like "*Wi-Fi Direct*" -or 
        $Desc -like "*Miniport*" -or 
        $Desc -like "*Pseudo*" -or
        $Desc -like "*Software*" -or
        $Desc -like "*WireGuard*" -or
        $Desc -like "*Tailscale*" -or
        $Desc -like "*Wintun*") {
        return $false
    }

    # 3. Inclusion logic
    # Some USB adapters report HardwareInterface=False and ConnectorPresent=False.
    # We check for physical connector OR explicit physical keywords.
    if ($Adapter.ConnectorPresent -eq $true -or $Adapter.HardwareInterface -eq $true) {
        return $true
    }

    if ($Desc -like "*Ethernet*" -or 
        $Desc -like "*GbE*" -or 
        $Desc -like "*WiFi*" -or 
        $Desc -like "*Gigabit*" -or
        $Desc -like "*Controller*" -or
        $Desc -like "*Realtek*" -or
        $Desc -like "*Intel*" -or
        $Desc -like "*802.11*") {
        return $true
    }

    return $false
}

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
    # Check if a known VPN adapter is connected and has an active network profile.
    # This prevents "always-up" virtual adapters from being mistaken for an active VPN tunnel.
    $vpnAdapters = Get-NetAdapter | Where-Object { (Test-IsVPNAdapter $_) -and $_.Status -eq "Up" }
    if (-not $vpnAdapters) { return $false }

    $vpnIndices = $vpnAdapters.InterfaceIndex
    $vpnProfiles = Get-NetConnectionProfile | Where-Object { $_.InterfaceIndex -in $vpnIndices }
    return ($null -ne $vpnProfiles)
}

function Manage-VPN {
    $Profiles = Get-NetConnectionProfile
    $NeedsVPN = $false
    $Reason = ""

    # --- Debug/Verbose Adapter Info ---
    $AllAdapters = Get-NetAdapter
    foreach ($a in $AllAdapters) {
        $isPhysical = Test-IsPhysicalAdapter $a
        $isVPN = Test-IsVPNAdapter $a
        # Only log details for adapters that are Up or were considered physical to avoid spamming disconnected Bluetooth etc.
        if ($a.Status -eq "Up" -or $isPhysical) {
            $statusStr = if ($isPhysical) { "PHYSICAL" } elseif ($isVPN) { "VPN" } else { "SKIPPED" }
            # Use inner log only if another diagnostic level is added, or just write-host for debug
            # Let's use a subtle log entry if skipped but Up
            if (-not $isPhysical -and -not $isVPN -and $a.Status -eq "Up") {
                Write-Log "Adapter Debug: [$($a.InterfaceDescription)] (Index: $($a.InterfaceIndex), Status: $($a.Status)) -> $statusStr (Connector: $($a.ConnectorPresent))" "Information"
            }
        }
    }

    # 1. Identify all actual physical network adapters that are currently UP
    $PhysicalAdapters = $AllAdapters | Where-Object { (Test-IsPhysicalAdapter $_) -and $_.Status -eq "Up" }

    if (-not $PhysicalAdapters) {
        Write-Log "No active physical network hardware found (e.g., Ethernet or WiFi)." "Warning"
        return $false # Keep checking
    }

    # 2. Get connection profiles for these physical adapters only
    $PhysicalIndices = $PhysicalAdapters.InterfaceIndex
    $PhysicalProfiles = $Profiles | Where-Object { $_.InterfaceIndex -in $PhysicalIndices }

    if (-not $PhysicalProfiles) {
        # This is expected for a few seconds during wake/login while DHCP/DNS is still initializing
        $AdapterDescs = $PhysicalAdapters | ForEach-Object { "$($_.InterfaceDescription) (Index: $($_.InterfaceIndex))" }
        Write-Log "Waiting for network connectivity profiles on: [$($AdapterDescs -join ', ')]..."

        # Diagnostic: Dump all profiles on system to see if any exist at all
        $AllProfilesDump = Get-NetConnectionProfile
        if ($AllProfilesDump) {
            $ProfileLines = $AllProfilesDump | ForEach-Object { "$($_.Name) (Cat: $($_.NetworkCategory), Index: $($_.InterfaceIndex))" }
            Write-Log "DEBUG: System Profiles: [$($ProfileLines -join ' | ')]"
        }
        else {
            Write-Log "DEBUG: Get-NetConnectionProfile returned NO profiles."
        }
        return $false
    }

    foreach ($p in $PhysicalProfiles) {
        if ($p.NetworkCategory -eq "Public") {
            # Check exceptions
            if ($p.Name -in $TrustedSpecificSSIDs) {
                Write-Log "Network [$($p.Name)] (Index: $($p.InterfaceIndex)) is Public but in Trusted List. Treating as Trusted."
            }
            else {
                $NeedsVPN = $true
                $Reason = "Network [$($p.Name)] on physical adapter (Index: $($p.InterfaceIndex)) is category Public (Untrusted)."
                break # Found one unsafe network, so we need VPN
            }
        }
        else {
            Write-Log "Network [$($p.Name)] (Index: $($p.InterfaceIndex)) is $($p.NetworkCategory) (Trusted)."
        }
    }

    $IsConnected = Get-VPNStatus

    if ($NeedsVPN) {
        if (-not $IsConnected) {
            if ($script:ActionTakenCount -ge 3) {
                Write-Log "Failed to connect VPN after 3 attempts. Giving up for this cycle." "Error"
                return $true # Stop looping
            }
            Write-Log "ACTION: Connecting VPN. Reason: $Reason"
            # Start OpenVPN
            Start-Process -FilePath $OpenVPNPath -ArgumentList "--command connect `"$OvnConfigName`"" -WindowStyle Hidden
            $script:ActionTakenCount++
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
            if ($script:ActionTakenCount -ge 3) {
                Write-Log "A VPN is still detected after 3 disconnect attempts. Likely a persistent VPN (like Tailscale) that we don't manage. Considering state compliant." "Warning"
                return $true # Stop looping
            }
            Write-Log "ACTION: Disconnecting VPN. Reason: All active networks are Trusted (Private/Domain)."
            Start-Process -FilePath $OpenVPNPath -ArgumentList "--command disconnect `"$OvnConfigName`"" -WindowStyle Hidden
            $script:ActionTakenCount++
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

exit
