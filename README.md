# Battery Telemetry for Codex

Small Windows PowerShell project that records local battery telemetry and keeps a fresh status snapshot in `data/current-status.json`.

## Scripts

- `scripts\collect-battery.ps1` records one sample, rebuilds the model, and refreshes `current-status.json`
- `scripts\rebuild-model.ps1` recomputes learned active and low-power drain rates
- `scripts\get-battery-status.ps1` prints a summary and JSON payload, or a chat-friendly summary with `-Brief`
- `scripts\show-battery.ps1` prints only the short chat-friendly battery summary
- `scripts\install-task.ps1` installs a Scheduled Task that runs the collector every minute and at logon
- `scripts\start-low-power-learning-session.ps1` records an unplug-to-replug low-power learning session and rebuilds the model when AC returns
- `scripts\get-history.ps1` summarizes monitored uptime, historical kWh, and estimated EUR from saved samples
- `scripts\start-dashboard.ps1` opens a local browser dashboard with Measure Now, History, and Close buttons
- `data\settings.json` configures the electricity tariff, VAT, monthly hours, and Dell adapter efficiency used for cost estimates

## Typical usage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect-battery.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\get-battery-status.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\get-battery-status.ps1 -Brief
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-battery.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-task.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-low-power-learning-session.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\get-history.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-dashboard.ps1
```

When the user asks Codex for battery state, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-battery.ps1
```

The status command automatically refreshes the sample when the cache is older than 3 minutes. Use `-Refresh` when you want to force a new sample immediately:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-battery.ps1 -Refresh
```

## Low-power learning session

Before unplugging the charger, start:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-low-power-learning-session.ps1
```

Then unplug the charger, close or turn off the screen, and plug the charger back in when the test is done. The session watcher writes `data\sessions\low-power-*.json`, rebuilds `data\model.json`, and then prints the updated battery summary.

## Output files

- `data\samples.csv`: append-only telemetry history
- `data\model.json`: learned drain-rate model
- `data\current-status.json`: latest status snapshot and estimates
- `data\install-state.json`: scheduled task install metadata
- `data\sessions\low-power-*.json`: completed or failed low-power learning sessions

## Local dashboard

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-dashboard.ps1
```

The dashboard opens at `http://127.0.0.1:8765/` and provides:

- `Izmjeri sada`: forces a fresh battery/cost measurement
- `Povijest`: reloads historical monitored time, kWh, and EUR estimates
- `Zatvori panel`: stops the local dashboard server

Codex cannot inject persistent native buttons into this chat UI, so this local dashboard is the persistent-button layer.

## Electricity cost estimate

The default cost model uses HEP Bijeli VT/NT household pricing, 13% VAT, and an 88% efficient older Dell adapter. Fixed monthly meter fees are excluded because they are paid regardless of the laptop.

The brief status includes:

- laptop-side watts from live battery discharge or learned history
- wall-side watts after adapter loss
- current VT/NT period
- estimated monthly kWh and EUR for 24/7 operation in the detected mode
- inferred display state when Windows exposes enough idle/display evidence

## Runtime interpretation

The main runtime estimate is based on the current measured discharge rate whenever the laptop is on battery. A closed or powered-off display is not treated as low-power by itself.

- `Ekran ugasen/zatvoren` only describes display/idle evidence.
- `Aktivan rad` means the laptop is still consuming battery at the measured live rate.
- `Standby/hibernacija` is a separate scenario and is shown separately because Windows must actually enter that mode for the multi-day estimate to apply.

## Notes

- This laptop uses Modern Standby (`Connected Standby`), so the low-power estimate models that behavior rather than classic `S3` sleep.
- If you later ask Codex for battery state while away from the laptop, the answer can be read from `data/current-status.json`.
