[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'CodexBatteryTelemetryCollector',
    [int]$IntervalMinutes = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

if ($IntervalMinutes -lt 1) {
    throw 'IntervalMinutes must be at least 1.'
}

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
Ensure-Directory -Path $paths.DataDir

$collectorPath = Join-Path $PSScriptRoot 'collect-battery.ps1'
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$actionArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $collectorPath
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$startBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
$intervalIso = 'PT{0}M' -f $IntervalMinutes

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$([System.Security.SecurityElement]::Escape($currentUser))</Author>
    <Description>Collects local battery telemetry for Codex battery status estimates.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$([System.Security.SecurityElement]::Escape($currentUser))</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>$intervalIso</Interval>
        <Duration>P3650D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$([System.Security.SecurityElement]::Escape($currentUser))</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$([System.Security.SecurityElement]::Escape($powershellPath))</Command>
      <Arguments>$([System.Security.SecurityElement]::Escape($actionArgs))</Arguments>
    </Exec>
  </Actions>
</Task>
"@

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled battery telemetry task')) {
    $xmlPath = Join-Path $env:TEMP ('codex-battery-task-{0}.xml' -f ([guid]::NewGuid().ToString('N')))
    try {
        [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
        $createOutput = schtasks /Create /TN $TaskName /XML $xmlPath /F 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($createOutput | Out-String).Trim())
        }
    }
    finally {
        if (Test-Path -LiteralPath $xmlPath) {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }

    $installState = [pscustomobject]@{
        taskName          = $TaskName
        intervalMinutes   = $IntervalMinutes
        collectorPath     = $collectorPath
        installedAt       = [DateTimeOffset]::Now.ToString('o')
        installMode       = 'schtasks_xml'
        currentStatusPath = $paths.CurrentStatusPath
    }

    Write-JsonFile -Path $paths.InstallStatePath -InputObject $installState
    $installState
}
