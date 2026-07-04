[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
Ensure-Directory -Path $paths.DataDir

$currentSnapshot = $null
try {
    $currentSnapshot = Get-BatterySnapshot
}
catch {
    $currentSnapshot = $null
}

$fullChargeCapacityMWh = if ($currentSnapshot) { $currentSnapshot.FullChargeCapacityMWh } else { $null }
$model = Build-BatteryModel -SamplesPath $paths.SamplesPath -SessionsDir $paths.SessionsDir -CurrentFullChargeCapacityMWh $fullChargeCapacityMWh
Write-JsonFile -Path $paths.ModelPath -InputObject $model

if (-not $Quiet) {
    $model
}
