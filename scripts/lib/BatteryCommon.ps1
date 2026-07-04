Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-ProjectRootFromScriptRoot {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ScriptRoot).Path
    $leaf = Split-Path -Leaf $resolvedRoot

    if ($leaf -eq 'lib') {
        return (Split-Path -Parent (Split-Path -Parent $resolvedRoot))
    }

    return (Split-Path -Parent $resolvedRoot)
}

function Get-ProjectPaths {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $dataDir = Join-Path $ProjectRoot 'data'

    [pscustomobject]@{
        ProjectRoot       = $ProjectRoot
        DataDir           = $dataDir
        SessionsDir       = Join-Path $dataDir 'sessions'
        SamplesPath       = Join-Path $dataDir 'samples.csv'
        ModelPath         = Join-Path $dataDir 'model.json'
        CurrentStatusPath = Join-Path $dataDir 'current-status.json'
        InstallStatePath  = Join-Path $dataDir 'install-state.json'
        SettingsPath      = Join-Path $dataDir 'settings.json'
    }
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        $InputObject
    )

    $parent = Split-Path -Parent $Path
    Ensure-Directory -Path $parent
    $json = $InputObject | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Test-ModelNeedsRefresh {
    param(
        [Parameter(Mandatory)]
        [string]$ModelPath,

        [int]$MaxAgeMinutes = 30
    )

    if (-not (Test-Path -LiteralPath $ModelPath)) {
        return $true
    }

    $lastWrite = (Get-Item -LiteralPath $ModelPath).LastWriteTime
    return ((Get-Date) - $lastWrite).TotalMinutes -ge $MaxAgeMinutes
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Get-BatterySettings {
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath
    )

    $defaults = [pscustomobject]@{
        tariffModel     = 'HEP_BIJELI_VT_NT'
        adapterEfficiency = 0.88
        vatRate         = 0.13
        monthlyHours    = 730
        oieEurPerKWh    = 0.013239
        tariffs         = [pscustomobject]@{
            HEP_BIJELI_VT_NT = [pscustomobject]@{
                currency                 = 'EUR'
                energyVTEurPerKWh        = 0.097189
                energyNTEurPerKWh        = 0.047688
                networkVTEurPerKWh       = 0.065702
                networkNTEurPerKWh       = 0.028689
                fixedMonthlyFeesExcluded = $true
            }
        }
        seasonSchedules = [pscustomobject]@{
            summer = [pscustomobject]@{ vtStartHour = 8; vtEndHour = 22 }
            winter = [pscustomobject]@{ vtStartHour = 7; vtEndHour = 21 }
        }
    }

    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        return $defaults
    }

    $settings = Read-JsonFile -Path $SettingsPath
    if (-not $settings) {
        return $defaults
    }

    return $settings
}

function Get-UserIdleSeconds {
    try {
        if (-not ('BatteryTelemetry.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
namespace BatteryTelemetry {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        public static uint GetIdleMilliseconds() {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref lii)) {
                return 0;
            }
            return ((uint)Environment.TickCount - lii.dwTime);
        }
    }
}
'@
        }

        return [math]::Round([BatteryTelemetry.NativeMethods]::GetIdleMilliseconds() / 1000.0, 1)
    }
    catch {
        return $null
    }
}

function Get-DisplayStateEstimate {
    param(
        [Nullable[int]]$DisplayTimeoutSeconds
    )

    $idleSeconds = Get-UserIdleSeconds
    $monitorAvailability = @(Get-SafeCimInstance -ClassName 'Win32_DesktopMonitor' |
        Select-Object -ExpandProperty Availability -ErrorAction SilentlyContinue)
    $evidence = New-Object System.Collections.Generic.List[string]
    $state = 'display_state_unknown'
    $confidence = 0.25

    if ($null -ne $idleSeconds) {
        $evidence.Add(('user_idle_seconds={0}' -f $idleSeconds))
    }

    if ($monitorAvailability.Count -gt 0) {
        $evidence.Add(('monitor_availability={0}' -f (($monitorAvailability | ForEach-Object { [string]$_ }) -join ',')))
    }

    if ($DisplayTimeoutSeconds -and $DisplayTimeoutSeconds -gt 0) {
        $evidence.Add(('display_timeout_seconds={0}' -f $DisplayTimeoutSeconds))
        if ($null -ne $idleSeconds -and $idleSeconds -ge ($DisplayTimeoutSeconds + 30)) {
            $state = 'display_likely_off'
            $confidence = 0.75
        }
        elseif ($null -ne $idleSeconds -and $idleSeconds -lt $DisplayTimeoutSeconds) {
            $state = 'display_likely_on'
            $confidence = 0.65
        }
    }

    if ($monitorAvailability | Where-Object { $_ -in @(7, 8, 13, 14) }) {
        if ($state -eq 'display_state_unknown') {
            $state = 'display_likely_off'
            $confidence = 0.55
        }
        $evidence.Add('monitor_reports_low_power_or_off')
    }

    [pscustomobject]@{
        state      = $state
        confidence = $confidence
        idleSeconds = $idleSeconds
        evidence   = @($evidence)
    }
}

function Get-SafeCimInstance {
    param(
        [Parameter(Mandatory)]
        [string]$ClassName,

        [string]$Namespace = 'root\cimv2'
    )

    try {
        return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-ActivePowerSchemeName {
    $output = powercfg /getactivescheme 2>$null
    if (-not $output) {
        return $null
    }

    $line = ($output | Select-Object -First 1).Trim()
    if ($line -match '\((?<name>[^)]+)\)\s*$') {
        return $matches['name']
    }

    return $line
}

function Get-DisplayTimeoutSeconds {
    param(
        [ValidateSet('AC', 'DC')]
        [string]$PowerSource
    )

    $output = powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null
    if (-not $output) {
        return $null
    }

    $pattern = if ($PowerSource -eq 'AC') {
        'Current AC Power Setting Index:\s+0x(?<value>[0-9a-fA-F]+)'
    }
    else {
        'Current DC Power Setting Index:\s+0x(?<value>[0-9a-fA-F]+)'
    }

    foreach ($line in $output) {
        if ($line -match $pattern) {
            return [Convert]::ToInt32($matches['value'], 16)
        }
    }

    return $null
}

function ConvertTo-NullableDouble {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [double]$text
    }
    catch {
        return $null
    }
}

function Get-ObjectPropertyValue {
    param(
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-DateTimeOffsetValue {
    param(
        [Parameter(Mandatory)]
        $Value
    )

    if ($Value -is [DateTimeOffset]) {
        return $Value
    }

    if ($Value -is [DateTime]) {
        return [DateTimeOffset]$Value
    }

    $text = [string]$Value
    return [DateTimeOffset]::ParseExact(
        $text,
        'o',
        $script:InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
}

function Convert-HtmlNumber {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $clean = $Text -replace '&nbsp;', '' -replace 'mWh', '' -replace '%', '' -replace '\s', ''
    if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq '-') {
        return $null
    }

    $sign = 1
    if ($clean.StartsWith('-')) {
        $sign = -1
        $clean = $clean.Substring(1)
    }

    $digits = $clean -replace '[^0-9]', ''
    if ([string]::IsNullOrWhiteSpace($digits)) {
        return $null
    }

    return $sign * [double]$digits
}

function Convert-HmsToMinutes {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $trimmed = $Text.Trim()
    if ($trimmed -notmatch '^(?<hours>\d+):(?<minutes>\d{2}):(?<seconds>\d{2})$') {
        return $null
    }

    $totalSeconds =
        ([int]$matches['hours'] * 3600) +
        ([int]$matches['minutes'] * 60) +
        [int]$matches['seconds']

    return [math]::Round($totalSeconds / 60.0, 4)
}

function Format-MinutesAsDuration {
    param(
        [Nullable[int]]$Minutes
    )

    if ($null -eq $Minutes -or $Minutes -lt 0) {
        return 'n/a'
    }

    $span = [TimeSpan]::FromMinutes($Minutes)

    if ($span.TotalHours -ge 24) {
        return ('{0:%d}d {0:hh}h {0:mm}m' -f $span)
    }

    if ($span.TotalHours -ge 1) {
        return ('{0:hh}h {0:mm}m' -f $span)
    }

    return ('{0:mm}m' -f $span)
}

function Get-BatterySnapshot {
    $batteryStatus = Get-SafeCimInstance -Namespace 'root\wmi' -ClassName 'BatteryStatus' | Select-Object -First 1
    if (-not $batteryStatus) {
        throw 'No battery was detected through root\wmi\BatteryStatus.'
    }

    $fullCapacity = Get-SafeCimInstance -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity' | Select-Object -First 1
    $portableBattery = Get-SafeCimInstance -ClassName 'Win32_PortableBattery' | Select-Object -First 1
    $win32Battery = Get-SafeCimInstance -ClassName 'Win32_Battery' | Select-Object -First 1
    $cycleInfo = Get-SafeCimInstance -Namespace 'root\wmi' -ClassName 'BatteryCycleCount' | Select-Object -First 1

    $fullChargeCapacityMWh = ConvertTo-NullableDouble $fullCapacity.FullChargedCapacity
    $remainingCapacityMWh = ConvertTo-NullableDouble $batteryStatus.RemainingCapacity
    $designCapacityMWh = ConvertTo-NullableDouble $portableBattery.DesignCapacity

    if ($null -eq $designCapacityMWh -and $fullChargeCapacityMWh) {
        $designCapacityMWh = $fullChargeCapacityMWh
    }

    $chargePercent = $null
    if ($fullChargeCapacityMWh -and $remainingCapacityMWh -ge 0) {
        $chargePercent = [math]::Round(($remainingCapacityMWh / $fullChargeCapacityMWh) * 100, 2)
    }
    elseif ($win32Battery.EstimatedChargeRemaining) {
        $chargePercent = [double]$win32Battery.EstimatedChargeRemaining
    }

    $dischargeRateMW = ConvertTo-NullableDouble $batteryStatus.DischargeRate
    $chargeRateMW = ConvertTo-NullableDouble $batteryStatus.ChargeRate
    $powerSource = if ($batteryStatus.PowerOnline) { 'AC' } else { 'Battery' }
    $displayTimeoutSeconds = Get-DisplayTimeoutSeconds -PowerSource $(if ($powerSource -eq 'AC') { 'AC' } else { 'DC' })
    $displayState = Get-DisplayStateEstimate -DisplayTimeoutSeconds $displayTimeoutSeconds

    $derivedMode = 'ac'
    if ($powerSource -eq 'Battery') {
        if (($batteryStatus.Discharging -eq $false) -or ($dischargeRateMW -and $dischargeRateMW -le 2500)) {
            $derivedMode = 'battery_low_power'
        }
        else {
            $derivedMode = 'battery_active'
        }
    }

    [pscustomobject]@{
        Timestamp              = [DateTimeOffset]::Now.ToString('o')
        BatteryName            = if ($win32Battery.Name) { [string]$win32Battery.Name } else { [string]$portableBattery.Name }
        PowerSource            = $powerSource
        IsCharging             = [bool]$batteryStatus.Charging
        IsDischarging          = [bool]$batteryStatus.Discharging
        ChargePercent          = $chargePercent
        RemainingCapacityMWh   = $remainingCapacityMWh
        FullChargeCapacityMWh  = $fullChargeCapacityMWh
        DesignCapacityMWh      = $designCapacityMWh
        ChargeRateMW           = if ($chargeRateMW -gt 0) { $chargeRateMW } else { $null }
        DischargeRateMW        = if ($dischargeRateMW -gt 0) { $dischargeRateMW } else { $null }
        DerivedMode            = $derivedMode
        PowerScheme            = Get-ActivePowerSchemeName
        DisplayTimeoutSeconds  = $displayTimeoutSeconds
        DisplayState           = $displayState.state
        DisplayStateConfidence = $displayState.confidence
        IdleSeconds            = $displayState.idleSeconds
        DisplayEvidence        = $displayState.evidence
        CycleCount             = if ($cycleInfo) { ConvertTo-NullableDouble $cycleInfo.CycleCount } else { $null }
    }
}

function Save-BatterySample {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        $Snapshot
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)

    $sample = [pscustomobject][ordered]@{
        timestamp             = $Snapshot.Timestamp
        batteryName           = $Snapshot.BatteryName
        powerSource           = $Snapshot.PowerSource
        isCharging            = $Snapshot.IsCharging
        isDischarging         = $Snapshot.IsDischarging
        chargePercent         = $Snapshot.ChargePercent
        remainingCapacityMWh  = $Snapshot.RemainingCapacityMWh
        fullChargeCapacityMWh = $Snapshot.FullChargeCapacityMWh
        designCapacityMWh     = $Snapshot.DesignCapacityMWh
        chargeRateMW          = $Snapshot.ChargeRateMW
        dischargeRateMW       = $Snapshot.DischargeRateMW
        derivedMode           = $Snapshot.DerivedMode
        powerScheme           = $Snapshot.PowerScheme
        displayTimeoutSeconds = $Snapshot.DisplayTimeoutSeconds
        displayState          = $Snapshot.DisplayState
        displayStateConfidence = $Snapshot.DisplayStateConfidence
        idleSeconds           = $Snapshot.IdleSeconds
        cycleCount            = $Snapshot.CycleCount
    }

    if (Test-Path -LiteralPath $Path) {
        $requiredColumns = @($sample.PSObject.Properties.Name)
        $header = Get-Content -LiteralPath $Path -TotalCount 1
        $missingColumns = @($requiredColumns | Where-Object { $header -notmatch ('(^|,)"?{0}"?(,|$)' -f [regex]::Escape($_)) })

        if ($missingColumns.Count -gt 0) {
            $existingRows = @(Import-Csv -LiteralPath $Path)
            $normalizedRows = foreach ($row in $existingRows) {
                $normalized = [ordered]@{}
                foreach ($column in $requiredColumns) {
                    $normalized[$column] = Get-ObjectPropertyValue -InputObject $row -Name $column
                }
                [pscustomobject]$normalized
            }
            $normalizedRows | Export-Csv -LiteralPath $Path -NoTypeInformation
        }

        $sample | Export-Csv -LiteralPath $Path -Append -NoTypeInformation
    }
    else {
        $sample | Export-Csv -LiteralPath $Path -NoTypeInformation
    }
}

function Get-SampleSegmentObservations {
    param(
        [Parameter(Mandatory)]
        [Object[]]$Samples
    )

    $recentCutoff = (Get-Date).AddDays(-14)
    $parsed = foreach ($sample in $Samples) {
        try {
            $timestamp = ConvertTo-DateTimeOffsetValue -Value $sample.timestamp
            if ($timestamp.LocalDateTime -lt $recentCutoff) {
                continue
            }

            [pscustomobject]@{
                Timestamp             = $timestamp
                PowerSource           = [string]$sample.powerSource
                DerivedMode           = [string]$sample.derivedMode
                RemainingCapacityMWh  = ConvertTo-NullableDouble $sample.remainingCapacityMWh
                DischargeRateMW       = ConvertTo-NullableDouble $sample.dischargeRateMW
            }
        }
        catch {
            continue
        }
    }

    $ordered = $parsed | Sort-Object Timestamp
    $observations = New-Object System.Collections.Generic.List[object]

    for ($i = 1; $i -lt $ordered.Count; $i++) {
        $previous = $ordered[$i - 1]
        $current = $ordered[$i]

        if ($previous.PowerSource -ne 'Battery' -or $current.PowerSource -ne 'Battery') {
            continue
        }

        if ($null -eq $previous.RemainingCapacityMWh -or $null -eq $current.RemainingCapacityMWh) {
            continue
        }

        $durationMinutes = ($current.Timestamp - $previous.Timestamp).TotalMinutes
        if ($durationMinutes -lt 1 -or $durationMinutes -gt 180) {
            continue
        }

        $capacityDelta = $previous.RemainingCapacityMWh - $current.RemainingCapacityMWh
        if ($capacityDelta -le 0) {
            continue
        }

        $rateMW = [math]::Round(($capacityDelta * 60.0) / $durationMinutes, 2)
        $mode = if ($previous.DerivedMode -eq 'battery_low_power' -and $current.DerivedMode -eq 'battery_low_power') {
            'battery_low_power'
        }
        else {
            'battery_active'
        }

        $observations.Add([pscustomobject]@{
                Source          = 'local_samples'
                State           = $mode
                DurationMinutes = [math]::Round($durationMinutes, 4)
                MilliWattHours  = [math]::Round($capacityDelta, 2)
                RateMW          = $rateMW
            })
    }

    return $observations
}

function Get-BatteryReportRecentUsageRows {
    param(
        [Nullable[double]]$FallbackFullChargeCapacityMWh
    )

    $outputPath = Join-Path $env:TEMP ('codex-battery-report-{0}.html' -f ([guid]::NewGuid().ToString('N')))
    try {
        powercfg /batteryreport /output $outputPath | Out-Null
        if (-not (Test-Path -LiteralPath $outputPath)) {
            return @()
        }

        $html = Get-Content -LiteralPath $outputPath -Raw
        $sectionMatch = [regex]::Match(
            $html,
            '(?is)<h2>Battery usage</h2>.*?<table.*?>(?<table>.*?)</table>'
        )

        if (-not $sectionMatch.Success) {
            return @()
        }

        $rowMatches = [regex]::Matches(
            $sectionMatch.Groups['table'].Value,
            '(?is)<tr class="(?:odd|even)[^"]*"><td class="dateTime">.*?</td><td class="state">\s*(?<state>[^<]+?)\s*</td><td class="hms">(?<duration>[^<]+)</td><td class="(?:percent|nullValue)">(?<percent>[^<]*)</td><td class="(?:mw|nullValue)">(?<mwh>[^<]*)</td></tr>'
        )

        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($rowMatch in $rowMatches) {
            $state = ($rowMatch.Groups['state'].Value -replace '\s+', ' ').Trim()
            $durationMinutes = Convert-HmsToMinutes -Text $rowMatch.Groups['duration'].Value
            $mwh = Convert-HtmlNumber -Text $rowMatch.Groups['mwh'].Value
            $percent = Convert-HtmlNumber -Text $rowMatch.Groups['percent'].Value

            if ($null -eq $mwh -and $percent -and $FallbackFullChargeCapacityMWh) {
                $mwh = [math]::Round(($FallbackFullChargeCapacityMWh * $percent) / 100.0, 2)
            }

            $rateMW = $null
            if ($durationMinutes -and $durationMinutes -gt 0 -and $mwh -and $mwh -gt 0) {
                $rateMW = [math]::Round(($mwh * 60.0) / $durationMinutes, 2)
            }

            $rows.Add([pscustomobject]@{
                    Source          = 'windows_battery_report'
                    State           = $state
                    DurationMinutes = $durationMinutes
                    PercentDrain    = $percent
                    MilliWattHours  = $mwh
                    RateMW          = $rateMW
                })
        }

        return $rows
    }
    finally {
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-LowPowerSessionObservations {
    param(
        [Parameter(Mandatory)]
        [string]$SessionsDir
    )

    if (-not (Test-Path -LiteralPath $SessionsDir)) {
        return @()
    }

    $observations = New-Object System.Collections.Generic.List[object]
    $sessionFiles = Get-ChildItem -LiteralPath $SessionsDir -Filter 'low-power-*.json' -File -ErrorAction SilentlyContinue

    foreach ($file in $sessionFiles) {
        try {
            $session = Read-JsonFile -Path $file.FullName
            if (-not $session -or $session.status -ne 'completed') {
                continue
            }

            $durationMinutes = ConvertTo-NullableDouble $session.durationMinutes
            $drainedMWh = ConvertTo-NullableDouble $session.drainedMWh
            $rateMW = ConvertTo-NullableDouble $session.lowPowerRateMW

            if ($null -eq $rateMW -and $durationMinutes -and $durationMinutes -gt 0 -and $drainedMWh -and $drainedMWh -gt 0) {
                $rateMW = [math]::Round(($drainedMWh * 60.0) / $durationMinutes, 2)
            }

            if ($durationMinutes -and $durationMinutes -gt 0 -and $drainedMWh -and $drainedMWh -gt 0 -and $rateMW -and $rateMW -gt 0) {
                $observations.Add([pscustomobject]@{
                        Source          = 'low_power_session'
                        State           = 'battery_low_power'
                        DurationMinutes = [math]::Round($durationMinutes, 4)
                        MilliWattHours  = [math]::Round($drainedMWh, 2)
                        RateMW          = [math]::Round($rateMW, 2)
                    })
            }
        }
        catch {
            continue
        }
    }

    return $observations
}

function Get-RobustRateEstimate {
    param(
        [AllowEmptyCollection()]
        [Object[]]$Observations = @(),

        [Parameter(Mandatory)]
        [string]$State,

        [Parameter(Mandatory)]
        [double]$MinRateMW,

        [Parameter(Mandatory)]
        [double]$MaxRateMW,

        [Parameter(Mandatory)]
        [double]$MinDurationMinutes
    )

    if (-not $Observations -or $Observations.Count -eq 0) {
        return $null
    }

    $filtered = $Observations |
        Where-Object {
            $_.State -eq $State -and
            $_.RateMW -and
            $_.RateMW -ge $MinRateMW -and
            $_.RateMW -le $MaxRateMW -and
            $_.DurationMinutes -and
            $_.DurationMinutes -ge $MinDurationMinutes
        }

    if (-not $filtered) {
        return $null
    }

    $ordered = $filtered | Sort-Object RateMW
    $trimCount = 0
    if ($ordered.Count -ge 5) {
        $trimCount = [math]::Floor($ordered.Count * 0.2)
    }

    $trimmed = $ordered
    if ($trimCount -gt 0 -and ($ordered.Count - ($trimCount * 2)) -ge 1) {
        $trimmed = $ordered[$trimCount..($ordered.Count - $trimCount - 1)]
    }

    $weightedTotal = ($trimmed | Measure-Object -Property DurationMinutes -Sum).Sum
    $weightedRate = 0.0
    foreach ($row in $trimmed) {
        $weightedRate += ($row.RateMW * $row.DurationMinutes)
    }

    $rateMW = [math]::Round($weightedRate / $weightedTotal, 2)
    $totalMinutes = [math]::Round(($trimmed | Measure-Object -Property DurationMinutes -Sum).Sum, 2)
    $confidence = [math]::Round(
        [math]::Min(1.0, $trimmed.Count / 6.0) *
        [math]::Min(1.0, $totalMinutes / 240.0),
        2
    )
    if (@($trimmed | Where-Object Source -eq 'low_power_session').Count -gt 0) {
        $confidence = [math]::Max($confidence, [math]::Round([math]::Min(1.0, $totalMinutes / 240.0), 2))
    }

    [pscustomobject]@{
        rateMW       = $rateMW
        sampleCount  = $trimmed.Count
        totalMinutes = $totalMinutes
        confidence   = $confidence
        source       = ($trimmed | Select-Object -First 1).Source
    }
}

function Select-PreferredRateEstimate {
    param(
        $Primary,
        $Fallback
    )

    if ($Primary -and ($Primary.confidence -ge 0.35 -or $Primary.sampleCount -ge 3)) {
        return $Primary
    }

    if ($Fallback) {
        return $Fallback
    }

    return $Primary
}

function Build-BatteryModel {
    param(
        [Parameter(Mandatory)]
        [string]$SamplesPath,

        [string]$SessionsDir,

        [Nullable[double]]$CurrentFullChargeCapacityMWh
    )

    $samples = @()
    if (Test-Path -LiteralPath $SamplesPath) {
        $samples = Import-Csv -LiteralPath $SamplesPath
    }

    $sampleObservations = @(Get-SampleSegmentObservations -Samples $samples)
    $sessionObservations = @(if ($SessionsDir) { Get-LowPowerSessionObservations -SessionsDir $SessionsDir })
    $recentUsageObservations = @(Get-BatteryReportRecentUsageRows -FallbackFullChargeCapacityMWh $CurrentFullChargeCapacityMWh)

    $activeSampleEstimate = Get-RobustRateEstimate -Observations $sampleObservations -State 'battery_active' -MinRateMW 500 -MaxRateMW 50000 -MinDurationMinutes 2
    $lowPowerSampleObservations = @($sampleObservations + $sessionObservations)
    $lowPowerSampleEstimate = Get-RobustRateEstimate -Observations $lowPowerSampleObservations -State 'battery_low_power' -MinRateMW 50 -MaxRateMW 5000 -MinDurationMinutes 5
    $activeReportEstimate = Get-RobustRateEstimate -Observations $recentUsageObservations -State 'Active' -MinRateMW 500 -MaxRateMW 50000 -MinDurationMinutes 10
    $lowPowerReportEstimate = Get-RobustRateEstimate -Observations $recentUsageObservations -State 'Connected standby' -MinRateMW 50 -MaxRateMW 5000 -MinDurationMinutes 5

    $activeEstimate = Select-PreferredRateEstimate -Primary $activeSampleEstimate -Fallback $activeReportEstimate
    $lowPowerEstimate = Select-PreferredRateEstimate -Primary $lowPowerSampleEstimate -Fallback $lowPowerReportEstimate

    $fullChargeCapacityMWh = $CurrentFullChargeCapacityMWh
    if (-not $fullChargeCapacityMWh -and $samples) {
        $latestCapacity = $samples |
            Sort-Object timestamp -Descending |
            Select-Object -First 1 -ExpandProperty fullChargeCapacityMWh
        $fullChargeCapacityMWh = ConvertTo-NullableDouble $latestCapacity
    }

    [pscustomobject]@{
        generatedAt                     = [DateTimeOffset]::Now.ToString('o')
        fullChargeCapacityMWh           = $fullChargeCapacityMWh
        sampleObservationCount          = @($sampleObservations).Count
        sessionObservationCount         = @($sessionObservations).Count
        recentUsageObservationCount     = @($recentUsageObservations).Count
        activeRate                      = $activeEstimate
        lowPowerRate                    = $lowPowerEstimate
        reportFallback                  = [pscustomobject]@{
            activeObservationCount   = @($recentUsageObservations | Where-Object State -eq 'Active').Count
            lowPowerObservationCount = @($recentUsageObservations | Where-Object State -eq 'Connected standby').Count
        }
    }
}

function Get-ModelRuntimeMinutes {
    param(
        [Nullable[double]]$RemainingCapacityMWh,
        [Nullable[double]]$RateMW
    )

    if ($null -eq $RemainingCapacityMWh -or $null -eq $RateMW -or $RateMW -le 0) {
        return $null
    }

    return [int][math]::Round(($RemainingCapacityMWh * 60.0) / $RateMW)
}

function Get-CurrentTariffPeriod {
    param(
        [Parameter(Mandatory)]
        $Settings,

        [DateTimeOffset]$Timestamp = [DateTimeOffset]::Now
    )

    $localDate = $Timestamp.LocalDateTime
    $isSummer = [TimeZoneInfo]::Local.IsDaylightSavingTime($localDate)
    $schedule = if ($isSummer) { $Settings.seasonSchedules.summer } else { $Settings.seasonSchedules.winter }
    $hour = $localDate.Hour
    $vtStart = [int]$schedule.vtStartHour
    $vtEnd = [int]$schedule.vtEndHour
    $period = if ($hour -ge $vtStart -and $hour -lt $vtEnd) { 'VT' } else { 'NT' }

    [pscustomobject]@{
        period      = $period
        season      = if ($isSummer) { 'summer' } else { 'winter' }
        vtStartHour = $vtStart
        vtEndHour   = $vtEnd
    }
}

function Get-TariffPrice {
    param(
        [Parameter(Mandatory)]
        $Settings,

        [Parameter(Mandatory)]
        [string]$Period
    )

    $tariff = $Settings.tariffs.($Settings.tariffModel)
    if (-not $tariff) {
        throw ('Unknown tariff model: {0}' -f $Settings.tariffModel)
    }

    $energy = if ($Period -eq 'VT') { [double]$tariff.energyVTEurPerKWh } else { [double]$tariff.energyNTEurPerKWh }
    $network = if ($Period -eq 'VT') { [double]$tariff.networkVTEurPerKWh } else { [double]$tariff.networkNTEurPerKWh }
    $oie = [double]$Settings.oieEurPerKWh
    $withoutVat = $energy + $network + $oie
    $withVat = $withoutVat * (1.0 + [double]$Settings.vatRate)

    [pscustomobject]@{
        currency                 = $tariff.currency
        energyEurPerKWh          = [math]::Round($energy, 6)
        networkEurPerKWh         = [math]::Round($network, 6)
        oieEurPerKWh             = [math]::Round($oie, 6)
        priceWithoutVatEurPerKWh = [math]::Round($withoutVat, 6)
        priceWithVatEurPerKWh    = [math]::Round($withVat, 6)
        fixedMonthlyFeesExcluded = [bool]$tariff.fixedMonthlyFeesExcluded
    }
}

function Get-EstimatedPowerCost {
    param(
        [Parameter(Mandatory)]
        $Snapshot,

        [Parameter(Mandatory)]
        $Model,

        [Parameter(Mandatory)]
        $Settings,

        [Nullable[double]]$ActiveRateMW,

        [Nullable[double]]$LowPowerRateMW,

        [string]$ActiveSource,

        [string]$LowPowerSource
    )

    $dcPowerMW = $null
    $powerSource = $null
    $confidence = $null
    $costMode = $Snapshot.DerivedMode

    if ($Snapshot.PowerSource -eq 'Battery' -and $Snapshot.DischargeRateMW -and $Snapshot.DischargeRateMW -gt 0) {
        $dcPowerMW = [double]$Snapshot.DischargeRateMW
        $powerSource = if ($Snapshot.DerivedMode -eq 'battery_low_power') { 'live_low_power_rate' } else { 'live_discharge_rate' }
        $confidence = if ($Snapshot.DerivedMode -eq 'battery_low_power') { 0.75 } else { 0.9 }
    }
    elseif ($Snapshot.DisplayState -eq 'display_likely_off' -and $LowPowerRateMW) {
        $dcPowerMW = [double]$LowPowerRateMW
        $powerSource = $LowPowerSource
        $confidence = ConvertTo-NullableDouble $Model.lowPowerRate.confidence
        $costMode = 'ac_estimated_low_power'
    }
    elseif ($ActiveRateMW) {
        $dcPowerMW = [double]$ActiveRateMW
        $powerSource = $ActiveSource
        $confidence = ConvertTo-NullableDouble $Model.activeRate.confidence
        $costMode = 'ac_estimated_active'
    }
    elseif ($LowPowerRateMW) {
        $dcPowerMW = [double]$LowPowerRateMW
        $powerSource = $LowPowerSource
        $confidence = ConvertTo-NullableDouble $Model.lowPowerRate.confidence
        $costMode = 'ac_estimated_low_power'
    }

    if ($null -eq $dcPowerMW) {
        return $null
    }

    $adapterEfficiency = [double]$Settings.adapterEfficiency
    if ($adapterEfficiency -le 0 -or $adapterEfficiency -gt 1) {
        throw 'adapterEfficiency must be > 0 and <= 1.'
    }

    $tariffPeriod = Get-CurrentTariffPeriod -Settings $Settings
    $price = Get-TariffPrice -Settings $Settings -Period $tariffPeriod.period
    $dcPowerW = $dcPowerMW / 1000.0
    $wallPowerW = $dcPowerW / $adapterEfficiency
    $monthlyKWh = ($wallPowerW / 1000.0) * [double]$Settings.monthlyHours
    $monthlyCost = $monthlyKWh * [double]$price.priceWithVatEurPerKWh

    [pscustomobject]@{
        mode                       = $costMode
        dcPowerW                   = [math]::Round($dcPowerW, 2)
        estimatedWallPowerW        = [math]::Round($wallPowerW, 2)
        adapterEfficiency          = $adapterEfficiency
        adapterLossPercent         = [math]::Round((1.0 - $adapterEfficiency) * 100.0, 1)
        tariffModel                = $Settings.tariffModel
        tariffNow                  = $tariffPeriod.period
        tariffSeason               = $tariffPeriod.season
        variablePriceEurPerKWh     = $price.priceWithVatEurPerKWh
        variablePriceWithoutVatEurPerKWh = $price.priceWithoutVatEurPerKWh
        monthlyHours               = [double]$Settings.monthlyHours
        monthlyKWh                 = [math]::Round($monthlyKWh, 2)
        monthlyCostEur             = [math]::Round($monthlyCost, 2)
        fixedMonthlyFeesExcluded   = $price.fixedMonthlyFeesExcluded
        costSource                 = $powerSource
        confidence                 = $confidence
    }
}

function Get-OsUptimeSummary {
    $os = Get-SafeCimInstance -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    if (-not $os -or -not $os.LastBootUpTime) {
        return $null
    }

    $bootTime = [DateTimeOffset]$os.LastBootUpTime
    $uptimeMinutes = [math]::Round(([DateTimeOffset]::Now - $bootTime).TotalMinutes, 1)

    [pscustomobject]@{
        bootTime      = $bootTime.ToString('o')
        uptimeMinutes = $uptimeMinutes
        uptime        = Format-MinutesAsDuration -Minutes ([int][math]::Round($uptimeMinutes))
    }
}

function New-HistoryBucket {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    [pscustomobject]@{
        name                  = $Name
        monitoredMinutes      = 0.0
        acMinutes             = 0.0
        batteryMinutes        = 0.0
        displayLikelyOffMinutes = 0.0
        estimatedKWh          = 0.0
        estimatedCostEur      = 0.0
        segmentCount          = 0
        costedSegmentCount    = 0
    }
}

function Add-HistorySegmentToBucket {
    param(
        [Parameter(Mandatory)]
        $Bucket,

        [Parameter(Mandatory)]
        $PreviousSample,

        [Parameter(Mandatory)]
        [double]$DurationMinutes,

        [Nullable[double]]$EstimatedKWh,

        [Nullable[double]]$EstimatedCostEur
    )

    $Bucket.monitoredMinutes = [math]::Round($Bucket.monitoredMinutes + $DurationMinutes, 4)
    $Bucket.segmentCount++

    if ([string](Get-ObjectPropertyValue -InputObject $PreviousSample -Name 'powerSource') -eq 'Battery') {
        $Bucket.batteryMinutes = [math]::Round($Bucket.batteryMinutes + $DurationMinutes, 4)
    }
    else {
        $Bucket.acMinutes = [math]::Round($Bucket.acMinutes + $DurationMinutes, 4)
    }

    if ([string](Get-ObjectPropertyValue -InputObject $PreviousSample -Name 'displayState') -eq 'display_likely_off') {
        $Bucket.displayLikelyOffMinutes = [math]::Round($Bucket.displayLikelyOffMinutes + $DurationMinutes, 4)
    }

    if ($null -ne $EstimatedKWh -and $null -ne $EstimatedCostEur) {
        $Bucket.estimatedKWh = [math]::Round($Bucket.estimatedKWh + [double]$EstimatedKWh, 8)
        $Bucket.estimatedCostEur = [math]::Round($Bucket.estimatedCostEur + [double]$EstimatedCostEur, 8)
        $Bucket.costedSegmentCount++
    }
}

function Complete-HistoryBucket {
    param(
        [Parameter(Mandatory)]
        $Bucket
    )

    [pscustomobject]@{
        name                    = $Bucket.name
        monitoredMinutes        = [math]::Round($Bucket.monitoredMinutes, 1)
        monitoredDuration       = Format-MinutesAsDuration -Minutes ([int][math]::Round($Bucket.monitoredMinutes))
        acMinutes               = [math]::Round($Bucket.acMinutes, 1)
        batteryMinutes          = [math]::Round($Bucket.batteryMinutes, 1)
        displayLikelyOffMinutes = [math]::Round($Bucket.displayLikelyOffMinutes, 1)
        estimatedKWh            = [math]::Round($Bucket.estimatedKWh, 4)
        estimatedCostEur        = [math]::Round($Bucket.estimatedCostEur, 4)
        segmentCount            = $Bucket.segmentCount
        costedSegmentCount      = $Bucket.costedSegmentCount
    }
}

function Get-SampleEstimatedRateMW {
    param(
        [Parameter(Mandatory)]
        $Sample,

        $Model
    )

    $dischargeRate = ConvertTo-NullableDouble (Get-ObjectPropertyValue -InputObject $Sample -Name 'dischargeRateMW')
    if ([string](Get-ObjectPropertyValue -InputObject $Sample -Name 'powerSource') -eq 'Battery' -and $dischargeRate -and $dischargeRate -gt 0) {
        return [pscustomobject]@{
            rateMW = $dischargeRate
            source = 'sample_discharge_rate'
        }
    }

    $lowPowerRate = $null
    $activeRate = $null
    if ($Model -and $Model.lowPowerRate) {
        $lowPowerRate = ConvertTo-NullableDouble $Model.lowPowerRate.rateMW
    }
    if ($Model -and $Model.activeRate) {
        $activeRate = ConvertTo-NullableDouble $Model.activeRate.rateMW
    }

    $derivedMode = [string](Get-ObjectPropertyValue -InputObject $Sample -Name 'derivedMode')
    $displayState = [string](Get-ObjectPropertyValue -InputObject $Sample -Name 'displayState')
    if (($derivedMode -eq 'battery_low_power' -or $displayState -eq 'display_likely_off') -and $lowPowerRate) {
        return [pscustomobject]@{
            rateMW = $lowPowerRate
            source = 'model_low_power_rate'
        }
    }

    if ($activeRate) {
        return [pscustomobject]@{
            rateMW = $activeRate
            source = 'model_active_rate'
        }
    }

    return $null
}

function Get-BatteryHistorySummary {
    param(
        [Parameter(Mandatory)]
        [string]$SamplesPath,

        $Model,

        [Parameter(Mandatory)]
        $Settings,

        [int]$MaxGapMinutes = 5
    )

    $now = [DateTimeOffset]::Now
    $samples = @()
    if (Test-Path -LiteralPath $SamplesPath) {
        $samples = @(Import-Csv -LiteralPath $SamplesPath | Sort-Object timestamp)
    }

    $all = New-HistoryBucket -Name 'all'
    $today = New-HistoryBucket -Name 'today'
    $last24h = New-HistoryBucket -Name 'last24h'
    $last7d = New-HistoryBucket -Name 'last7d'
    $tariffBreakdown = @{}

    for ($i = 1; $i -lt $samples.Count; $i++) {
        try {
            $previous = $samples[$i - 1]
            $current = $samples[$i]
            $previousTime = ConvertTo-DateTimeOffsetValue -Value $previous.timestamp
            $currentTime = ConvertTo-DateTimeOffsetValue -Value $current.timestamp
            $durationMinutes = ($currentTime - $previousTime).TotalMinutes

            if ($durationMinutes -le 0 -or $durationMinutes -gt $MaxGapMinutes) {
                continue
            }

            $rate = Get-SampleEstimatedRateMW -Sample $previous -Model $Model
            $estimatedKWh = $null
            $estimatedCostEur = $null

            if ($rate -and $rate.rateMW -gt 0) {
                $tariffPeriod = Get-CurrentTariffPeriod -Settings $Settings -Timestamp $previousTime
                $price = Get-TariffPrice -Settings $Settings -Period $tariffPeriod.period
                $estimatedKWh = (([double]$rate.rateMW / 1000000.0) / [double]$Settings.adapterEfficiency) * ($durationMinutes / 60.0)
                $estimatedCostEur = $estimatedKWh * [double]$price.priceWithVatEurPerKWh

                $tariffKey = $tariffPeriod.period
                if (-not $tariffBreakdown.ContainsKey($tariffKey)) {
                    $tariffBreakdown[$tariffKey] = [pscustomobject]@{
                        minutes          = 0.0
                        estimatedKWh     = 0.0
                        estimatedCostEur = 0.0
                    }
                }
                $tariffBreakdown[$tariffKey].minutes = [math]::Round($tariffBreakdown[$tariffKey].minutes + $durationMinutes, 4)
                $tariffBreakdown[$tariffKey].estimatedKWh = [math]::Round($tariffBreakdown[$tariffKey].estimatedKWh + $estimatedKWh, 8)
                $tariffBreakdown[$tariffKey].estimatedCostEur = [math]::Round($tariffBreakdown[$tariffKey].estimatedCostEur + $estimatedCostEur, 8)
            }

            Add-HistorySegmentToBucket -Bucket $all -PreviousSample $previous -DurationMinutes $durationMinutes -EstimatedKWh $estimatedKWh -EstimatedCostEur $estimatedCostEur

            if ($previousTime.LocalDateTime.Date -eq $now.LocalDateTime.Date) {
                Add-HistorySegmentToBucket -Bucket $today -PreviousSample $previous -DurationMinutes $durationMinutes -EstimatedKWh $estimatedKWh -EstimatedCostEur $estimatedCostEur
            }
            if ($previousTime -ge $now.AddHours(-24)) {
                Add-HistorySegmentToBucket -Bucket $last24h -PreviousSample $previous -DurationMinutes $durationMinutes -EstimatedKWh $estimatedKWh -EstimatedCostEur $estimatedCostEur
            }
            if ($previousTime -ge $now.AddDays(-7)) {
                Add-HistorySegmentToBucket -Bucket $last7d -PreviousSample $previous -DurationMinutes $durationMinutes -EstimatedKWh $estimatedKWh -EstimatedCostEur $estimatedCostEur
            }
        }
        catch {
            continue
        }
    }

    $firstSampleTime = $null
    $lastSampleTime = $null
    if ($samples.Count -gt 0) {
        $firstSampleTime = (ConvertTo-DateTimeOffsetValue -Value $samples[0].timestamp).ToString('o')
        $lastSampleTime = (ConvertTo-DateTimeOffsetValue -Value $samples[$samples.Count - 1].timestamp).ToString('o')
    }

    [pscustomobject]@{
        generatedAt     = $now.ToString('o')
        sampleCount     = $samples.Count
        firstSampleTime = $firstSampleTime
        lastSampleTime  = $lastSampleTime
        maxGapMinutes   = $MaxGapMinutes
        uptime          = Get-OsUptimeSummary
        periods         = @(
            Complete-HistoryBucket -Bucket $today
            Complete-HistoryBucket -Bucket $last24h
            Complete-HistoryBucket -Bucket $last7d
            Complete-HistoryBucket -Bucket $all
        )
        tariffBreakdown = [pscustomobject]$tariffBreakdown
        note            = 'Monitored time is inferred from telemetry samples. Long gaps are excluded.'
    }
}

function Get-BatteryStatusPayload {
    param(
        [Parameter(Mandatory)]
        $Snapshot,

        $Model,

        $Settings
    )

    $activeRateMW = $null
    $activeConfidence = $null
    $activeSource = $null

    if ($Snapshot.PowerSource -eq 'Battery' -and $Snapshot.DischargeRateMW -and $Snapshot.DerivedMode -eq 'battery_active') {
        $activeRateMW = $Snapshot.DischargeRateMW
        $activeConfidence = 0.9
        $activeSource = 'live_discharge_rate'
    }
    elseif ($Model.activeRate) {
        $activeRateMW = ConvertTo-NullableDouble $Model.activeRate.rateMW
        $activeConfidence = ConvertTo-NullableDouble $Model.activeRate.confidence
        $activeSource = [string]$Model.activeRate.source
    }

    $lowPowerRateMW = $null
    $lowPowerConfidence = $null
    $lowPowerSource = $null

    if ($Snapshot.PowerSource -eq 'Battery' -and $Snapshot.DischargeRateMW -and $Snapshot.DerivedMode -eq 'battery_low_power') {
        $lowPowerRateMW = $Snapshot.DischargeRateMW
        $lowPowerConfidence = 0.75
        $lowPowerSource = 'live_low_power_rate'
    }
    elseif ($Model.lowPowerRate) {
        $lowPowerRateMW = ConvertTo-NullableDouble $Model.lowPowerRate.rateMW
        $lowPowerConfidence = ConvertTo-NullableDouble $Model.lowPowerRate.confidence
        $lowPowerSource = [string]$Model.lowPowerRate.source
    }

    $activeMinutes = Get-ModelRuntimeMinutes -RemainingCapacityMWh $Snapshot.RemainingCapacityMWh -RateMW $activeRateMW
    $lowPowerMinutes = Get-ModelRuntimeMinutes -RemainingCapacityMWh $Snapshot.RemainingCapacityMWh -RateMW $lowPowerRateMW
    if (-not $Settings) {
        $Settings = Get-BatterySettings -SettingsPath ''
    }
    $powerCost = Get-EstimatedPowerCost -Snapshot $Snapshot -Model $Model -Settings $Settings -ActiveRateMW $activeRateMW -LowPowerRateMW $lowPowerRateMW -ActiveSource $activeSource -LowPowerSource $lowPowerSource

    [pscustomobject]@{
        generatedAt               = [DateTimeOffset]::Now.ToString('o')
        lastSampleTime            = $Snapshot.Timestamp
        batteryName               = $Snapshot.BatteryName
        powerSource               = $Snapshot.PowerSource
        derivedMode               = $Snapshot.DerivedMode
        chargePercent             = $Snapshot.ChargePercent
        remainingCapacityMWh      = $Snapshot.RemainingCapacityMWh
        fullChargeCapacityMWh     = $Snapshot.FullChargeCapacityMWh
        designCapacityMWh         = $Snapshot.DesignCapacityMWh
        dischargeRateMW           = $Snapshot.DischargeRateMW
        chargeRateMW              = $Snapshot.ChargeRateMW
        powerScheme               = $Snapshot.PowerScheme
        displayTimeoutSeconds     = $Snapshot.DisplayTimeoutSeconds
        display                   = [pscustomobject]@{
            state      = $Snapshot.DisplayState
            confidence = $Snapshot.DisplayStateConfidence
            idleSeconds = $Snapshot.IdleSeconds
            evidence   = $Snapshot.DisplayEvidence
        }
        powerCost                 = $powerCost
        estimatedActiveMinutes    = $activeMinutes
        estimatedLowPowerMinutes  = $lowPowerMinutes
        activeEstimate            = [pscustomobject]@{
            rateMW      = $activeRateMW
            confidence  = $activeConfidence
            source      = $activeSource
            description = 'If AC is unplugged now and current workload continues.'
        }
        lowPowerEstimate          = [pscustomobject]@{
            rateMW      = $lowPowerRateMW
            confidence  = $lowPowerConfidence
            source      = $lowPowerSource
            description = 'Connected-standby or very low-power screen-off style state on this laptop.'
        }
    }
}

function Get-BatteryStatusSummary {
    param(
        [Parameter(Mandatory)]
        $Status
    )

    $sampleTime = ConvertTo-DateTimeOffsetValue -Value $Status.lastSampleTime
    $sampleAgeMinutes = [math]::Round(([DateTimeOffset]::Now - $sampleTime).TotalMinutes, 1)

    @(
        ('Battery: {0}%' -f ([math]::Round([double]$Status.chargePercent, 1)))
        ('Source: {0}' -f $Status.powerSource)
        ('Last sample: {0} ({1} min ago)' -f $sampleTime.ToString('yyyy-MM-dd HH:mm:ss zzz'), $sampleAgeMinutes)
        ('Estimate if unplugged now: {0}' -f (Format-MinutesAsDuration -Minutes $Status.estimatedActiveMinutes))
        ('Estimate in low-power/connected-standby mode: {0}' -f (Format-MinutesAsDuration -Minutes $Status.estimatedLowPowerMinutes))
        ('Active estimate source: {0}' -f $(if ($Status.activeEstimate.source) { $Status.activeEstimate.source } else { 'n/a' }))
        ('Low-power estimate source: {0}' -f $(if ($Status.lowPowerEstimate.source) { $Status.lowPowerEstimate.source } else { 'n/a' }))
    ) -join [Environment]::NewLine
}

function Get-BatteryChatSummary {
    param(
        [Parameter(Mandatory)]
        $Status
    )

    $sampleTime = ConvertTo-DateTimeOffsetValue -Value $Status.lastSampleTime
    $sampleAgeMinutes = [math]::Round(([DateTimeOffset]::Now - $sampleTime).TotalMinutes, 1)
    $sourceLabel = if ($Status.powerSource -eq 'AC') { 'struja' } else { 'baterija' }
    $activeDuration = Format-MinutesAsDuration -Minutes $Status.estimatedActiveMinutes
    $lowPowerDuration = Format-MinutesAsDuration -Minutes $Status.estimatedLowPowerMinutes
    $displayLabel = switch ($Status.display.state) {
        'display_likely_off' { 'ekran vjerojatno ugasen' }
        'display_likely_on' { 'ekran vjerojatno ukljucen' }
        default { 'stanje ekrana nepoznato' }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Baterija: {0}%' -f ([math]::Round([double]$Status.chargePercent, 1))))
    $lines.Add(('Napajanje: {0}' -f $sourceLabel))
    $lines.Add(('Mod: {0}, {1}' -f $Status.derivedMode, $displayLabel))
    $lines.Add(('Zadnje mjerenje: {0} ({1} min staro)' -f $sampleTime.ToString('yyyy-MM-dd HH:mm'), $sampleAgeMinutes))
    $lines.Add(('Ako iskljucis struju: oko {0}' -f $activeDuration))
    $lines.Add(('Zatvoren ekran / low-power: oko {0}' -f $lowPowerDuration))

    if ($Status.powerCost) {
        $lines.Add(('Trenutna procjena laptopa: {0} W' -f $Status.powerCost.dcPowerW))
        $lines.Add(('Procjena iz zida s Dell adapterom {0:p0}: {1} W' -f [double]$Status.powerCost.adapterEfficiency, $Status.powerCost.estimatedWallPowerW))
        $lines.Add(('Mjesecno 24/7 ovako: {0} kWh, oko {1} EUR ({2}, {3} EUR/kWh)' -f $Status.powerCost.monthlyKWh, $Status.powerCost.monthlyCostEur, $Status.powerCost.tariffNow, $Status.powerCost.variablePriceEurPerKWh))
    }

    $activeConfidence = ConvertTo-NullableDouble $Status.activeEstimate.confidence
    if ($null -ne $activeConfidence -and $activeConfidence -lt 0.35) {
        $lines.Add('Napomena: procjena aktivnog rada je jos niske pouzdanosti dok se ne skupi vise rada na bateriji.')
    }

    return ($lines -join [Environment]::NewLine)
}
