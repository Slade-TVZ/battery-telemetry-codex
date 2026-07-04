[CmdletBinding()]
param(
    [switch]$Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$statusScript = Join-Path $PSScriptRoot 'get-battery-status.ps1'
if ($Refresh) {
    & $statusScript -Refresh -Brief
}
else {
    & $statusScript -Brief
}
