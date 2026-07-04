[CmdletBinding()]
param(
    [switch]$ForceModelRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
Ensure-Directory -Path $paths.DataDir

$snapshot = Get-BatterySnapshot
Save-BatterySample -Path $paths.SamplesPath -Snapshot $snapshot

if ($ForceModelRefresh -or (Test-ModelNeedsRefresh -ModelPath $paths.ModelPath)) {
    $rebuildScript = Join-Path $PSScriptRoot 'rebuild-model.ps1'
    & $rebuildScript -Quiet | Out-Null
}

$model = Read-JsonFile -Path $paths.ModelPath
$status = Get-BatteryStatusPayload -Snapshot $snapshot -Model $model
Write-JsonFile -Path $paths.CurrentStatusPath -InputObject $status

$status
