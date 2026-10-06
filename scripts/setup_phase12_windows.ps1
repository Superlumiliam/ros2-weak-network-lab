# Run from Windows administrator PowerShell using the command printed by WSL setup.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}$')]
    [string]$RobotIP,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{1,5}-\d{1,5}$')]
    [string]$DataPorts,
    [ValidateSet('Up', 'Check', 'Down')]
    [string]$Action = 'Up'
)
$ErrorActionPreference = 'Stop'
$parsedIP = [System.Net.IPAddress]::Parse($RobotIP)
if ($parsedIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'RobotIP must be IPv4.'
}
$bounds = $DataPorts.Split('-')
if ([int]$bounds[0] -lt 1 -or [int]$bounds[1] -gt 65535 -or [int]$bounds[0] -gt [int]$bounds[1]) {
    throw 'Invalid TCP port range.'
}
$admin = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as administrator and run the same command.'
}
Get-Command Get-NetFirewallHyperVRule -ErrorAction Stop | Out-Null
# WSL creator ID documented by Microsoft; verify it exists on this host.
$creator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $creator | Out-Null
$name = 'ROS2-WeakNet-DDS-Dynamic'
$existing = Get-NetFirewallHyperVRule -ErrorAction Stop | Where-Object { $_.Name -eq $name }
if ($Action -eq 'Down') {
    if ($existing -and $PSCmdlet.ShouldProcess($name, 'Remove Phase12 rule')) {
        Remove-NetFirewallHyperVRule -Name $name
    }
    return
}
if ($Action -eq 'Up' -and $PSCmdlet.ShouldProcess($name, "Allow WSL inbound TCP $DataPorts from $RobotIP")) {
    $settings = @{
        Name = $name
        VMCreatorId = $creator
        Protocol = 'TCP'
        LocalPorts = $DataPorts
        RemoteAddresses = $RobotIP
    }
    if ($existing) {
        if ([string]$existing.Direction -ne 'Inbound' -or [string]$existing.Action -ne 'Allow') {
            throw 'Existing rule has unexpected direction/action; inspect it before proceeding.'
        }
        Set-NetFirewallHyperVRule @settings
    } else {
        New-NetFirewallHyperVRule @settings -DisplayName 'ROS2 WeakNet DDS dynamic ports from robot' -Direction Inbound -Action Allow | Out-Null
    }
}
if ($WhatIfPreference -and -not $existing) { return }
Get-NetFirewallHyperVRule -PolicyStore ActiveStore -Name $name |
    Format-List Name,Direction,Action,VMCreatorId,Protocol,LocalPorts,RemoteAddresses,EnforcementStatus
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $creator |
    Format-List Enabled,DefaultInboundAction,DefaultOutboundAction,AllowHostPolicyMerge
Get-NetFirewallHyperVProfile -PolicyStore ActiveStore |
    Format-Table Name,AllowLocalFirewallRules
Write-Host 'Verify receipt on Jetson with setup verify; rule creation alone is not proof of delivery.'
