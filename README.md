# Datadog IIS Monitoring with PowerShell

Collect IIS and ASP.NET performance metrics from a Windows Server and send them to Datadog automatically — **without changing your application code**.

This script reads Windows built-in performance counters and sends **13 metrics** to Datadog every 15 seconds via DogStatsD (UDP 8125). It uses only PowerShell — no compiler, no Python, no extra tools.

---

## What metrics you will see in Datadog

| Metric | Performance Counter | What it shows |
|---|---|---|
| `aspnet.requests.current` | `ASP.NET v4.0.30319\Requests Current` | Requests being processed right now |
| `aspnet.requests.queued` | `ASP.NET v4.0.30319\Requests Queued` | Requests waiting to be processed |
| `aspnet.requests.rejected` | `ASP.NET v4.0.30319\Requests Rejected` | Requests dropped because the queue was full |
| `aspnet.requests.in_queue` | `ASP.NET v4.0.30319\Requests In Native Queue` | Requests in the Windows kernel queue |
| `aspnet.request.execution_time` | `ASP.NET v4.0.30319\Request Execution Time` | Average time to process a request (ms) |
| `aspnet.request.wait_time` | `ASP.NET v4.0.30319\Request Wait Time` | Average time a request waits before starting (ms) |
| `aspnet.app.requests_executing` | `ASP.NET Applications(*)\Requests Executing` | Requests executing across all app pools (sum) |
| `iis.connections.current` | `Web Service(_Total)\Current Connections` | Active HTTP connections right now |
| `iis.requests.get` | `Web Service(_Total)\Total Get Requests` | Total GET requests served |
| `iis.requests.post` | `Web Service(_Total)\Total Post Requests` | Total POST requests served |
| `w3wp.cpu_pct` | `Process(w3wp*)\% Processor Time` | CPU % used by IIS worker processes (sum) |
| `w3wp.memory_bytes` | `Process(w3wp*)\Working Set` | Memory used by IIS worker processes (sum) |
| `w3wp.active_requests` | `W3SVC_W3WP(*)\Active Requests` | Active requests across all app pool workers (sum) |

---

## How it works

```
IIS / ASP.NET  (your existing app - nothing changes)
      |
      | Windows collects performance data automatically
      v
 ps_metrics.ps1  <- this script (runs every 15 seconds)
      |
      | UDP -> 127.0.0.1:8125
      v
 Datadog Agent  (already on your server)
      |
      | HTTPS
      v
 Datadog
```

---

## Datadog Dashboard

A ready-made dashboard with all 13 metrics is included in this repo: **`dashboard.json`**

### Import the dashboard

1. Go to [app.datadoghq.com/dashboard/lists](https://app.datadoghq.com/dashboard/lists)
2. Click **New Dashboard** -> **Import dashboard JSON**
3. Paste the contents of `dashboard.json`
4. Set the `host` template variable to your server hostname

Or import via API:

```powershell
# From PowerShell on any machine with curl
$body = Get-Content dashboard.json -Raw
Invoke-RestMethod `
    -Uri "https://api.datadoghq.com/api/v1/dashboard" `
    -Method Post `
    -Headers @{ "DD-API-KEY" = "<YOUR_API_KEY>"; "DD-APPLICATION-KEY" = "<YOUR_APP_KEY>" } `
    -ContentType "application/json" `
    -Body $body
```

---

## Before you start

Make sure you have:

- [ ] Windows Server 2016, 2019, or 2022
- [ ] IIS installed and running
- [ ] Datadog Agent 7 installed on the same server
- [ ] PowerShell open as Administrator

> **Note:** This works when `infrastructure_mode: basic` is set in `datadog.yaml`.
> That mode blocks native integrations but DogStatsD (UDP port 8125) still works — which is exactly what this script uses.

---

## Step 1 - Open PowerShell as Administrator

Click **Start** -> type `PowerShell` -> right-click **Windows PowerShell** -> click **Run as administrator**.

Run all commands from this guide in that window.

---

## Step 2 - Confirm the Datadog Agent is ready

```powershell
netstat -an | findstr ":8125"
```

You should see this line:
```
UDP    127.0.0.1:8125    *:*
```

This confirms the Datadog Agent is listening for metrics.

**If nothing appears**, restart the Agent:
```powershell
Restart-Service datadogagent
```
Then run the `netstat` command again.

---

## Step 3 - Create a folder for the script

```powershell
New-Item -ItemType Directory -Path "C:\DatadogMetrics" -Force
```

---

## Step 4 - Download the script

```powershell
Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/eranrh86/datadog-iis-powershell/main/ps_metrics.ps1" `
    -OutFile "C:\DatadogMetrics\ps_metrics.ps1"
```

---

## Step 5 - Set your tags

Open the script in Notepad:
```powershell
notepad C:\DatadogMetrics\ps_metrics.ps1
```

Find this line near the top and change it to match your environment:
```powershell
$tags = "env:production,app:your-app,tech:aspnet,tech:iis,collector:powershell"
```

For example:
```powershell
$tags = "env:production,app:my-website,tech:aspnet,tech:iis,collector:powershell"
```

Save and close Notepad.

---

## Step 6 - Test the script manually (optional but recommended)

Run the script once to see it working before setting it up as a background task:
```powershell
powershell -ExecutionPolicy Bypass -File C:\DatadogMetrics\ps_metrics.ps1
```

You should see:
```
Datadog IIS metrics collector starting
Sending to 127.0.0.1:8125 every 15s
```

If you see that it is working. Press `Ctrl+C` to stop. Now go to Datadog -> Metrics Explorer and search for `iis.requests.get` — it should appear within 30 seconds.

---

## Step 7 - Install as a Scheduled Task (runs automatically)

This installs the script as a background task that starts automatically when the server boots:

```powershell
$action   = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\DatadogMetrics\ps_metrics.ps1"

$trigger  = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
                -ExecutionTimeLimit 0 `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "Datadog-IIS-PowerShell" `
    -Action $action `
    -Trigger $trigger `
    -RunLevel Highest `
    -User "SYSTEM" `
    -Settings $settings `
    -Force

# Start it now (don't wait for reboot)
Start-ScheduledTask -TaskName "Datadog-IIS-PowerShell"
```

---

## Step 8 - Confirm it is running

```powershell
(Get-ScheduledTask -TaskName "Datadog-IIS-PowerShell").State
```

Expected output: `Running`

---

## Step 9 - Validate metrics in Datadog

1. Go to [app.datadoghq.com/metric/explorer](https://app.datadoghq.com/metric/explorer)
2. Search for `aspnet.requests.current`
3. All 13 metrics should appear within **30-60 seconds**

**Quick test** - send one metric manually to confirm the pipeline works end to end:
```powershell
$udp = New-Object System.Net.Sockets.UdpClient
$udp.Connect("127.0.0.1", 8125)
$b = [System.Text.Encoding]::UTF8.GetBytes("iis.healthcheck:1|g|#env:production")
$udp.Send($b, $b.Length) | Out-Null
$udp.Close()
Write-Host "Test metric sent"
```

Search for `iis.healthcheck` in Metrics Explorer. If it appears, the full pipeline is working.

---

## Day-to-day

### Stop the collector
```powershell
Stop-ScheduledTask -TaskName "Datadog-IIS-PowerShell"
```

### Start the collector
```powershell
Start-ScheduledTask -TaskName "Datadog-IIS-PowerShell"
```

### Restart the collector
```powershell
Stop-ScheduledTask -TaskName "Datadog-IIS-PowerShell"
Start-ScheduledTask -TaskName "Datadog-IIS-PowerShell"
```

### Update tags or settings
```powershell
# 1. Stop
Stop-ScheduledTask -TaskName "Datadog-IIS-PowerShell"

# 2. Edit the script
notepad C:\DatadogMetrics\ps_metrics.ps1

# 3. Start again
Start-ScheduledTask -TaskName "Datadog-IIS-PowerShell"
```

### View error logs

If something goes wrong, the script writes errors to the Windows Event Log:
```powershell
Get-EventLog -LogName Application -Source "DD-PSMetrics" -Newest 20 | Format-List
```

### Remove everything
```powershell
Stop-ScheduledTask -TaskName "Datadog-IIS-PowerShell" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "Datadog-IIS-PowerShell" -Confirm:$false
Remove-Item "C:\DatadogMetrics" -Recurse -Force
```

---

## Troubleshooting

### No metrics appear in Datadog after 2 minutes

**Check 1 - Is DogStatsD listening?**
```powershell
netstat -an | findstr ":8125"
```
Must show `UDP 127.0.0.1:8125 *:*`.
If not: `Restart-Service datadogagent`

**Check 2 - Is the task running?**
```powershell
(Get-ScheduledTask -TaskName "Datadog-IIS-PowerShell").State
```
Must show `Running`. If not: `Start-ScheduledTask -TaskName "Datadog-IIS-PowerShell"`

**Check 3 - Does the pipeline work at all?**
Run the Quick test from Step 9. If `iis.healthcheck` appears in Datadog, the DogStatsD pipeline is fine and the issue is with reading performance counters.

---

### `w3wp.cpu_pct`, `w3wp.memory_bytes`, and `w3wp.active_requests` show no data

IIS shuts down the `w3wp.exe` worker process after **20 minutes of no traffic** (the default idle timeout). When w3wp is not running, there is nothing to measure.

**Fix** - send some requests to restart the worker:
```powershell
1..10 | ForEach-Object {
    Invoke-WebRequest http://localhost/ -UseBasicParsing | Out-Null
}
```
Metrics will resume within 15 seconds.

**Prevent it in production** - open IIS Manager:
`Application Pools` -> right-click your pool -> `Advanced Settings` -> set **Idle Time-out (minutes)** to `0`

---

### `aspnet.app.requests_executing` shows no data

This counter reads from `ASP.NET Applications(*)\Requests Executing` using the `__Total__` instance. It requires at least one ASP.NET 4.x application pool to be registered in IIS. The `iis.*` and `w3wp.*` counters will still work without it.

---

### Script exits immediately instead of running

The script runs in a continuous loop. If it exits, check the Windows Event Log:
```powershell
Get-EventLog -LogName Application -Source "DD-PSMetrics" -Newest 10 | Format-List
```

Common causes:
- Performance counter category name differs on your server - open `perfmon.exe` -> Add Counters to find the exact names
- Missing permissions - confirm the Scheduled Task runs as `SYSTEM`

---

## Files

| File | Purpose |
|---|---|
| `ps_metrics.ps1` | The metrics collector - edit `$tags` at the top to customize |
| `dashboard.json` | Datadog dashboard definition - import to get all 13 metrics visualized instantly |
