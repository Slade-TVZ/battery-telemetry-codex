[CmdletBinding()]
param(
    [switch]$JsonOnly,
    [int]$MaxGapMinutes = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
$settings = Get-BatterySettings -SettingsPath $paths.SettingsPath
$model = Read-JsonFile -Path $paths.ModelPath

$history = Get-BatteryHistorySummary -SamplesPath $paths.SamplesPath -Model $model -Settings $settings -MaxGapMinutes $MaxGapMinutes

if ($JsonOnly) {
    $history | ConvertTo-Json -Depth 8
    return
}

Write-Output ('Uzoraka: {0}' -f $history.sampleCount)
if ($history.uptime) {
    Write-Output ('Windows ukljucen od: {0} ({1})' -f ([DateTimeOffset]::Parse($history.uptime.bootTime).ToString('yyyy-MM-dd HH:mm'), $history.uptime.uptime))
}

foreach ($period in $history.periods) {
    Write-Output ('{0}: praceno {1}, AC {2} min, baterija {3} min, ekran off {4} min, {5} kWh, {6} EUR' -f `
            $period.name, `
            $period.monitoredDuration, `
            $period.acMinutes, `
            $period.batteryMinutes, `
            $period.displayLikelyOffMinutes, `
            $period.estimatedKWh, `
            $period.estimatedCostEur)
}

Write-Output $history.note
