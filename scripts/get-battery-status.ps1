[CmdletBinding()]
param(
    [switch]$Refresh,
    [switch]$RefreshModel,
    [switch]$Brief,
    [switch]$JsonOnly,
    [int]$MaxAgeMinutes = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
Ensure-Directory -Path $paths.DataDir

$status = $null

if ($Refresh -or -not (Test-Path -LiteralPath $paths.CurrentStatusPath)) {
    $collectScript = Join-Path $PSScriptRoot 'collect-battery.ps1'
    if ($RefreshModel) {
        $status = & $collectScript -ForceModelRefresh
    }
    else {
        $status = & $collectScript
    }
}
else {
    $status = Read-JsonFile -Path $paths.CurrentStatusPath
    if ($status -and $MaxAgeMinutes -gt 0) {
        $sampleTime = ConvertTo-DateTimeOffsetValue -Value $status.lastSampleTime
        $sampleAgeMinutes = ([DateTimeOffset]::Now - $sampleTime).TotalMinutes
        if ($sampleAgeMinutes -gt $MaxAgeMinutes) {
            $collectScript = Join-Path $PSScriptRoot 'collect-battery.ps1'
            if ($RefreshModel) {
                $status = & $collectScript -ForceModelRefresh
            }
            else {
                $status = & $collectScript
            }
        }
    }
}

if (-not $status) {
    throw 'Battery status data is not available yet. Run collect-battery.ps1 first.'
}

if ($JsonOnly) {
    $status | ConvertTo-Json -Depth 8
}
elseif ($Brief) {
    Get-BatteryChatSummary -Status $status
}
else {
    $summary = Get-BatteryStatusSummary -Status $status
    Write-Output $summary
    Write-Output ''
    $status | ConvertTo-Json -Depth 8
}
