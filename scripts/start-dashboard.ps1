[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BatteryCommon.ps1')

$projectRoot = Get-ProjectRootFromScriptRoot -ScriptRoot $PSScriptRoot
$paths = Get-ProjectPaths -ProjectRoot $projectRoot
Ensure-Directory -Path $paths.DataDir

function Send-DashboardResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,

        [Parameter(Mandatory)]
        [string]$Body,

        [string]$ContentType = 'application/json; charset=utf-8',

        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Get-DashboardStatus {
    param(
        [switch]$Refresh
    )

    $settings = Get-BatterySettings -SettingsPath $paths.SettingsPath

    if ($Refresh -or -not (Test-Path -LiteralPath $paths.CurrentStatusPath)) {
        $collectScript = Join-Path $PSScriptRoot 'collect-battery.ps1'
        return & $collectScript
    }

    $status = Read-JsonFile -Path $paths.CurrentStatusPath
    if (-not $status) {
        $collectScript = Join-Path $PSScriptRoot 'collect-battery.ps1'
        return & $collectScript
    }

    $sampleTime = ConvertTo-DateTimeOffsetValue -Value $status.lastSampleTime
    if (([DateTimeOffset]::Now - $sampleTime).TotalMinutes -gt 3) {
        $collectScript = Join-Path $PSScriptRoot 'collect-battery.ps1'
        return & $collectScript
    }

    return $status
}

function Get-DashboardHistory {
    $settings = Get-BatterySettings -SettingsPath $paths.SettingsPath
    $model = Read-JsonFile -Path $paths.ModelPath
    Get-BatteryHistorySummary -SamplesPath $paths.SamplesPath -Model $model -Settings $settings
}

$html = @'
<!doctype html>
<html lang="hr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Battery Telemetry</title>
  <style>
    :root {
      --bg: #f3efe4;
      --panel: #fffaf0;
      --ink: #1f2a24;
      --muted: #6a716a;
      --accent: #176f5d;
      --accent-2: #d37b2d;
      --line: #ddd2bc;
    }

    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: Georgia, "Times New Roman", serif;
      color: var(--ink);
      background:
        radial-gradient(circle at 10% 10%, rgba(211, 123, 45, .22), transparent 28rem),
        radial-gradient(circle at 90% 0%, rgba(23, 111, 93, .18), transparent 22rem),
        linear-gradient(135deg, #f3efe4, #e8dfcd);
    }

    main {
      max-width: 1080px;
      margin: 0 auto;
      padding: 28px;
    }

    header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 18px;
      margin-bottom: 22px;
    }

    h1 {
      margin: 0;
      font-size: clamp(32px, 6vw, 72px);
      line-height: .9;
      letter-spacing: -0.06em;
    }

    .subtitle {
      margin-top: 12px;
      color: var(--muted);
      font-family: "Lucida Console", Consolas, monospace;
      font-size: 13px;
    }

    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      justify-content: flex-end;
    }

    button {
      border: 1px solid var(--ink);
      background: var(--ink);
      color: #fffaf0;
      padding: 12px 16px;
      border-radius: 999px;
      font-weight: 700;
      cursor: pointer;
      box-shadow: 0 10px 20px rgba(31, 42, 36, .12);
    }

    button.secondary {
      background: transparent;
      color: var(--ink);
    }

    button.warn {
      background: var(--accent-2);
      border-color: var(--accent-2);
      color: #1f160c;
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 16px;
    }

    .card {
      grid-column: span 4;
      background: rgba(255, 250, 240, .78);
      border: 1px solid var(--line);
      border-radius: 28px;
      padding: 20px;
      backdrop-filter: blur(10px);
      min-height: 150px;
    }

    .wide { grid-column: span 8; }
    .full { grid-column: 1 / -1; }

    .label {
      color: var(--muted);
      font-family: "Lucida Console", Consolas, monospace;
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: .08em;
    }

    .value {
      margin-top: 10px;
      font-size: clamp(28px, 5vw, 52px);
      line-height: .95;
      letter-spacing: -.04em;
    }

    .small {
      margin-top: 10px;
      color: var(--muted);
      font-size: 14px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-family: "Lucida Console", Consolas, monospace;
      font-size: 13px;
    }

    th, td {
      text-align: left;
      border-bottom: 1px solid var(--line);
      padding: 10px 8px;
    }

    th { color: var(--muted); }
    .status-line {
      margin-top: 16px;
      color: var(--muted);
      font-family: "Lucida Console", Consolas, monospace;
      font-size: 12px;
    }

    @media (max-width: 760px) {
      main { padding: 18px; }
      header { display: block; }
      .actions { justify-content: flex-start; margin-top: 18px; }
      .card, .wide { grid-column: 1 / -1; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Battery<br>Telemetry</h1>
        <div class="subtitle">Lokalni panel za mjerenje, cijenu i povijest rada.</div>
      </div>
      <div class="actions">
        <button id="measure">Izmjeri sada</button>
        <button id="history" class="secondary">Povijest</button>
        <button id="close" class="warn">Zatvori panel</button>
      </div>
    </header>

    <section class="grid">
      <article class="card">
        <div class="label">Baterija</div>
        <div id="charge" class="value">--%</div>
        <div id="source" class="small">Cekam mjerenje...</div>
      </article>
      <article class="card">
        <div class="label">Sadasnja potrosnja</div>
        <div id="runtime" class="value">--</div>
        <div id="lowPower" class="small">Standby/hibernacija: --</div>
      </article>
      <article class="card">
        <div class="label">Mjesecno ovako</div>
        <div id="cost" class="value">-- EUR</div>
        <div id="watts" class="small">-- W iz zida</div>
      </article>
      <article class="card wide">
        <div class="label">Stanje</div>
        <div id="mode" class="value">--</div>
        <div id="lastSample" class="small">--</div>
      </article>
      <article class="card">
        <div class="label">Windows uptime</div>
        <div id="uptime" class="value">--</div>
        <div class="small">Od zadnjeg bootanja.</div>
      </article>
      <article class="card full">
        <div class="label">Povijest potrosnje i ukljucenosti</div>
        <div style="overflow:auto; margin-top: 12px;">
          <table>
            <thead>
              <tr>
                <th>Period</th>
                <th>Praceno</th>
                <th>AC min</th>
                <th>Baterija min</th>
                <th>Ekran off min</th>
                <th>kWh</th>
                <th>EUR</th>
              </tr>
            </thead>
            <tbody id="historyRows"></tbody>
          </table>
        </div>
      </article>
    </section>
    <div id="statusLine" class="status-line">Spremno.</div>
  </main>

  <script>
    const fmt = new Intl.NumberFormat('hr-HR', { maximumFractionDigits: 2 });

    function minutesToDuration(minutes) {
      if (minutes === null || minutes === undefined || Number.isNaN(Number(minutes))) return '--';
      const total = Math.max(0, Math.round(Number(minutes)));
      const days = Math.floor(total / 1440);
      const hours = Math.floor((total % 1440) / 60);
      const mins = total % 60;
      if (days > 0) return `${days}d ${hours}h ${mins}m`;
      if (hours > 0) return `${hours}h ${mins}m`;
      return `${mins}m`;
    }

    function setStatus(text) {
      document.getElementById('statusLine').textContent = text;
    }

    function modeLabel(status) {
      const displayState = status.display && status.display.state;
      const displayText = displayState === 'display_likely_off'
        ? 'ekran ugasen/zatvoren'
        : displayState === 'display_likely_on'
          ? 'ekran vjerojatno ukljucen'
          : 'stanje ekrana nepoznato';

      if (status.derivedMode === 'battery_active') return `Aktivan rad, ${displayText}`;
      if (status.derivedMode === 'battery_low_power') return `Low-power/standby, ${displayText}`;
      if (status.derivedMode === 'ac') return `Na struji, ${displayText}`;
      return `${status.derivedMode || '--'} / ${displayText}`;
    }

    async function loadStatus(refresh) {
      setStatus(refresh ? 'Mjerim sada...' : 'Ucitavam status...');
      const response = await fetch(`/api/status${refresh ? '?refresh=1' : ''}`);
      if (!response.ok) throw new Error(await response.text());
      const status = await response.json();
      const scenarios = status.runtimeScenarios || {};
      const current = scenarios.currentMeasured || {};
      const standby = scenarios.standbyOrHibernate || {};
      const primaryMinutes = current.minutes ?? status.estimatedActiveMinutes;
      const standbyMinutes = standby.minutes ?? status.estimatedLowPowerMinutes;
      document.getElementById('charge').textContent = `${fmt.format(status.chargePercent)}%`;
      document.getElementById('source').textContent = status.powerSource === 'AC' ? 'Na struji' : 'Na bateriji';
      document.getElementById('runtime').textContent = minutesToDuration(primaryMinutes);
      document.getElementById('lowPower').textContent = `Standby/hibernacija, nije trenutno stanje: ${minutesToDuration(standbyMinutes)}`;
      document.getElementById('mode').textContent = modeLabel(status);
      document.getElementById('lastSample').textContent = `Zadnje mjerenje: ${new Date(status.lastSampleTime).toLocaleString()}`;
      if (status.powerCost) {
        const telemetry = status.powerTelemetry || {};
        document.getElementById('cost').textContent = `${fmt.format(status.powerCost.monthlyCostEur)} EUR`;
        const parts = [
          `${fmt.format(status.powerCost.estimatedWallPowerW)} W iz zida`,
          `${fmt.format(status.powerCost.monthlyKWh)} kWh/mj`
        ];
        if (telemetry.raplPackageW) parts.push(`CPU/RAPL ${fmt.format(telemetry.raplPackageW)} W`);
        if (telemetry.batteryChargeW) parts.push(`punjenje ${fmt.format(telemetry.batteryChargeW)} W`);
        if (telemetry.source) parts.push(`izvor ${telemetry.source}`);
        document.getElementById('watts').textContent = parts.join(', ');
      }
      setStatus('Status osvjezen.');
    }

    async function loadHistory() {
      setStatus('Ucitavam povijest...');
      const response = await fetch('/api/history');
      if (!response.ok) throw new Error(await response.text());
      const history = await response.json();
      document.getElementById('uptime').textContent = history.uptime ? history.uptime.uptime : '--';
      const rows = (history.periods || []).map(period => `
        <tr>
          <td>${period.name}</td>
          <td>${period.monitoredDuration}</td>
          <td>${fmt.format(period.acMinutes)}</td>
          <td>${fmt.format(period.batteryMinutes)}</td>
          <td>${fmt.format(period.displayLikelyOffMinutes)}</td>
          <td>${fmt.format(period.estimatedKWh)}</td>
          <td>${fmt.format(period.estimatedCostEur)}</td>
        </tr>
      `).join('');
      document.getElementById('historyRows').innerHTML = rows || '<tr><td colspan="7">Jos nema dovoljno uzoraka.</td></tr>';
      setStatus(`Povijest osvjezena. Uzoraka: ${history.sampleCount}.`);
    }

    document.getElementById('measure').addEventListener('click', () => loadStatus(true).then(loadHistory).catch(err => setStatus(err.message)));
    document.getElementById('history').addEventListener('click', () => loadHistory().catch(err => setStatus(err.message)));
    document.getElementById('close').addEventListener('click', async () => {
      setStatus('Zatvaram lokalni server...');
      await fetch('/api/close', { method: 'POST' });
      window.close();
      document.body.innerHTML = '<main><h1>Panel zatvoren</h1><p>Lokalni server je zaustavljen. Ovaj tab mozes zatvoriti.</p></main>';
    });

    loadStatus(false).then(loadHistory).catch(err => setStatus(err.message));
  </script>
</body>
</html>
'@

$listener = [System.Net.HttpListener]::new()
$url = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($url)
$listener.Start()

if (-not $NoBrowser) {
    Start-Process $url
}

Write-Output "Battery dashboard: $url"
Write-Output 'Use the Zatvori panel button to stop the local server.'

$shouldStop = $false
while (-not $shouldStop) {
    $context = $listener.GetContext()
    try {
        $path = $context.Request.Url.AbsolutePath
        if ($path -eq '/') {
            Send-DashboardResponse -Context $context -Body $html -ContentType 'text/html; charset=utf-8'
        }
        elseif ($path -eq '/api/status') {
            $refresh = $context.Request.QueryString['refresh'] -eq '1'
            $status = Get-DashboardStatus -Refresh:$refresh
            Send-DashboardResponse -Context $context -Body ($status | ConvertTo-Json -Depth 8)
        }
        elseif ($path -eq '/api/history') {
            $history = Get-DashboardHistory
            Send-DashboardResponse -Context $context -Body ($history | ConvertTo-Json -Depth 8)
        }
        elseif ($path -eq '/api/close') {
            Send-DashboardResponse -Context $context -Body (@{ ok = $true } | ConvertTo-Json)
            $shouldStop = $true
        }
        else {
            Send-DashboardResponse -Context $context -Body (@{ error = 'Not found' } | ConvertTo-Json) -StatusCode 404
        }
    }
    catch {
        Send-DashboardResponse -Context $context -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -StatusCode 500
    }
}

$listener.Stop()
$listener.Close()
