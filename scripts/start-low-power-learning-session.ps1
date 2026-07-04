[CmdletBinding()]
param(
    [int]$PollSeconds = 60,
    [int]$MinBatteryMinutes = 5,
    [int]$MaxHours = 48,
    [switch]$NoInitialRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

if ($PollSeconds -lt 5) {
    throw 'PollSeconds must be at least 5.'
}

if ($MinBatteryMinutes -lt 0) {
    throw 'MinBatteryMinutes cannot be negative.'
}

if ($MaxHours -lt 1) {
    throw 'MaxHours must be at least 1.'
}

function Get-SessionSnapshot {
    param(
        [switch]$Refresh
    )

    if ($Refresh) {
        $collectScript = Join-Path $PSScriptRoot 'collect-battery.ps1'
        & $collectScript | Out-Null
    }

    $snapshot = Get-BatterySnapshot
    $status = Read-JsonFile -Path $paths.CurrentStatusPath

    [pscustomobject]@{
        Snapshot = $snapshot
        Status   = $status
    }
}

function Get-SessionRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        $StartSnapshot,

        $BatteryStartSnapshot,

        $EndSnapshot,

        [string]$StopReason,

        [string]$ErrorMessage
    )

    $now = [DateTimeOffset]::Now
    $startTime = ConvertTo-DateTimeOffsetValue -Value $StartSnapshot.Timestamp
    $batteryStartTime = if ($BatteryStartSnapshot) { ConvertTo-DateTimeOffsetValue -Value $BatteryStartSnapshot.Timestamp } else { $null }
    $endTime = if ($EndSnapshot) { ConvertTo-DateTimeOffsetValue -Value $EndSnapshot.Timestamp } else { $now }
    $drainedMWh = $null
    $durationMinutes = $null
    $rateMW = $null

    if ($BatteryStartSnapshot -and $EndSnapshot) {
        $durationMinutes = [math]::Round(($endTime - $batteryStartTime).TotalMinutes, 4)
        $drainedMWh = [math]::Round(([double]$BatteryStartSnapshot.RemainingCapacityMWh - [double]$EndSnapshot.RemainingCapacityMWh), 2)

        if ($durationMinutes -gt 0 -and $drainedMWh -gt 0) {
            $rateMW = [math]::Round(($drainedMWh * 60.0) / $durationMinutes, 2)
        }
    }

    [pscustomobject]@{
        status                    = $Status
        stopReason                = $StopReason
        errorMessage              = $ErrorMessage
        createdAt                 = $startTime.ToString('o')
        completedAt               = if ($EndSnapshot) { $endTime.ToString('o') } else { $null }
        batteryStartAt            = if ($BatteryStartSnapshot) { $batteryStartTime.ToString('o') } else { $null }
        durationMinutes           = $durationMinutes
        minBatteryMinutes         = $MinBatteryMinutes
        pollSeconds               = $PollSeconds
        startPowerSource          = $StartSnapshot.PowerSource
        startCapacityMWh          = $StartSnapshot.RemainingCapacityMWh
        batteryStartCapacityMWh   = if ($BatteryStartSnapshot) { $BatteryStartSnapshot.RemainingCapacityMWh } else { $null }
        endPowerSource            = if ($EndSnapshot) { $EndSnapshot.PowerSource } else { $null }
        endCapacityMWh            = if ($EndSnapshot) { $EndSnapshot.RemainingCapacityMWh } else { $null }
        drainedMWh                = $drainedMWh
        lowPowerRateMW            = $rateMW
        startChargePercent        = $StartSnapshot.ChargePercent
        batteryStartChargePercent = if ($BatteryStartSnapshot) { $BatteryStartSnapshot.ChargePercent } else { $null }
        endChargePercent          = if ($EndSnapshot) { $EndSnapshot.ChargePercent } else { $null }
    }
}

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
Ensure-Directory -Path $paths.DataDir
Ensure-Directory -Path $paths.SessionsDir

$sessionId = 'low-power-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$sessionPath = Join-Path $paths.SessionsDir ($sessionId + '.json')
$deadline = [DateTimeOffset]::Now.AddHours($MaxHours)
$batteryWasSeen = $false
$startSnapshot = $null
$batteryStartSnapshot = $null
$lastSnapshot = $null

try {
    $initial = Get-SessionSnapshot -Refresh:(!$NoInitialRefresh)
    $startSnapshot = $initial.Snapshot
    $lastSnapshot = $startSnapshot

    if ($startSnapshot.PowerSource -eq 'Battery') {
        $batteryWasSeen = $true
        $batteryStartSnapshot = $startSnapshot
        $session = Get-SessionRecord -Status 'running_on_battery' -StartSnapshot $startSnapshot -BatteryStartSnapshot $batteryStartSnapshot -EndSnapshot $null -StopReason $null -ErrorMessage $null
    }
    else {
        $session = Get-SessionRecord -Status 'waiting_for_battery' -StartSnapshot $startSnapshot -BatteryStartSnapshot $null -EndSnapshot $null -StopReason $null -ErrorMessage $null
    }
    Write-JsonFile -Path $sessionPath -InputObject $session

    Write-Output ('Low-power learning session started: {0}' -f $sessionPath)
    Write-Output 'Unplug the charger, close/turn off the screen, then plug the charger back in when done.'
    if ($batteryWasSeen) {
        Write-Output ('Battery mode detected at session start: {0}.' -f $batteryStartSnapshot.Timestamp)
    }

    while ([DateTimeOffset]::Now -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $current = Get-SessionSnapshot
        $lastSnapshot = $current.Snapshot

        if ($lastSnapshot.PowerSource -eq 'Battery') {
            if (-not $batteryWasSeen) {
                $batteryWasSeen = $true
                $batteryStartSnapshot = $lastSnapshot
                $session = Get-SessionRecord -Status 'running_on_battery' -StartSnapshot $startSnapshot -BatteryStartSnapshot $batteryStartSnapshot -EndSnapshot $null -StopReason $null -ErrorMessage $null
                Write-JsonFile -Path $sessionPath -InputObject $session
                Write-Output ('Battery mode detected at {0}.' -f $batteryStartSnapshot.Timestamp)
            }

            continue
        }

        if ($batteryWasSeen -and $lastSnapshot.PowerSource -eq 'AC') {
            $batteryStartTime = ConvertTo-DateTimeOffsetValue -Value $batteryStartSnapshot.Timestamp
            $endTime = ConvertTo-DateTimeOffsetValue -Value $lastSnapshot.Timestamp
            $batteryMinutes = ($endTime - $batteryStartTime).TotalMinutes

            if ($batteryMinutes -lt $MinBatteryMinutes) {
                Write-Output ('AC returned after {0:n1} minutes; waiting for at least {1} battery minutes.' -f $batteryMinutes, $MinBatteryMinutes)
                continue
            }

            $session = Get-SessionRecord -Status 'completed' -StartSnapshot $startSnapshot -BatteryStartSnapshot $batteryStartSnapshot -EndSnapshot $lastSnapshot -StopReason 'ac_returned' -ErrorMessage $null
            Write-JsonFile -Path $sessionPath -InputObject $session

            $rebuildScript = Join-Path $PSScriptRoot 'rebuild-model.ps1'
            & $rebuildScript -Quiet | Out-Null

            $showScript = Join-Path $PSScriptRoot 'show-battery.ps1'
            Write-Output 'Low-power learning session completed and model rebuilt.'
            Write-Output ('Duration: {0:n1} min; drained: {1} mWh; learned low-power rate: {2} mW' -f $session.durationMinutes, $session.drainedMWh, $session.lowPowerRateMW)
            Write-Output ''
            & $showScript -Refresh
            exit 0
        }
    }

    $session = Get-SessionRecord -Status 'timed_out' -StartSnapshot $startSnapshot -BatteryStartSnapshot $batteryStartSnapshot -EndSnapshot $lastSnapshot -StopReason 'max_hours_reached' -ErrorMessage $null
    Write-JsonFile -Path $sessionPath -InputObject $session
    throw ('Low-power learning session timed out after {0} hours.' -f $MaxHours)
}
catch {
    if ($startSnapshot) {
        $session = Get-SessionRecord -Status 'failed' -StartSnapshot $startSnapshot -BatteryStartSnapshot $batteryStartSnapshot -EndSnapshot $lastSnapshot -StopReason 'error' -ErrorMessage $_.Exception.Message
        Write-JsonFile -Path $sessionPath -InputObject $session
    }

    throw
}
