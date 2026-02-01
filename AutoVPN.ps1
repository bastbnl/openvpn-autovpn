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
# AutoVPN.ps1
# Automates OpenVPN connection based on Windows Network Category (Public vs Private)
# Author: Antigravity
# Version: 1.0

# --- CONFIGURATION ---
$OpenVPNPath = "C:\Program Files\OpenVPN\bin\openvpn-gui.exe"
$OvnConfigName = "openvpn.pretty-private.ovpn" # CHANGE THIS to your actual config name
$LogFile = "$PSScriptRoot\vpn_automation.log"
$EventSource = "OpenVPN-AutoVPN"
$TrustedSpecificSSIDs = @("MySecretHomeWiFi") # Optional: specific SSIDs to always trust even if Public

# --- FUNCTIONS ---

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
        return
    }

    foreach ($p in $PhysicalProfiles) {
        if ($p.NetworkCategory -eq "Public") {
            # Check exceptions
            if ($p.Name -in $TrustedSpecificSSIDs) {
                Write-Log "Network [$($p.Name)] is Public but in Trusted List. Treating as Trusted and will not connect to VPN."
            }
            else {
                $NeedsVPN = $true
                $Reason = "Network [$($p.Name)] in network category $($p.NetworkCategory)) is not a Trusted network."
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
        }
        else {
            Write-Log "VPN is already connected on untrusted network [$($p.Name)]."
        }
    }
    else {
        # We are on Trusted networks
        if ($IsConnected) {
            Write-Log "ACTION: Disconnecting VPN. Reason: All active networks are Trusted (Private/Domain)."
            Start-Process -FilePath $OpenVPNPath -ArgumentList "--command disconnect `"$OvnConfigName`"" -WindowStyle Hidden
        }
        else {
            Write-Log "Safe on trusted network [$($p.Name)]. VPN is disconnected."
        }
    }
}

# --- MAIN ---
Write-Log "--- AutoVPN Check Started ---"
try {
    Manage-VPN
}
catch {
    Write-Log "Critical Error: $_" "Error"
}
