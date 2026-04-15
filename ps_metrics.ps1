# =============================================================================
# Datadog IIS/ASP.NET Metrics Collector — PowerShell
# =============================================================================
# Reads Windows Performance Counters and sends 13 IIS/ASP.NET metrics
# to Datadog every 15 seconds via DogStatsD (UDP port 8125).
#
# Requirements:
#   - PowerShell 5.1 or later (built into Windows Server 2016+)
#   - Datadog Agent installed and running on the same server
#   - No additional software needed
#
# How to run manually:
#   powershell -ExecutionPolicy Bypass -File ps_metrics.ps1
#
# How to install as a background Scheduled Task:
#   See README.md
# =============================================================================

# ─── CONFIGURE THESE ─────────────────────────────────────────────────────────
$tags     = "env:production,app:your-app,tech:aspnet,tech:iis,collector:powershell"
$interval = 15          # seconds between metric collections
$statsd   = "127.0.0.1" # Datadog Agent DogStatsD host
$port     = 8125         # Datadog Agent DogStatsD port
# ─────────────────────────────────────────────────────────────────────────────

# Register a Windows Event Log source so errors appear in Event Viewer
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists("DD-PSMetrics")) {
        New-EventLog -LogName Application -Source "DD-PSMetrics"
    }
} catch {}


function Send-Gauge {
    <#
    .SYNOPSIS
        Send one metric to Datadog via DogStatsD UDP.
    #>
    param(
        [string]$metric,
        [double]$value,
        [string]$tags
    )
    try {
        $udp     = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($statsd, $port)
        $payload = "${metric}:${value}|g|#${tags}"
        $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $udp.Send($bytes, $bytes.Length) | Out-Null
        $udp.Close()
    } catch {
        Write-EventLog -LogName Application -Source "DD-PSMetrics" -EventId 1001 `
            -EntryType Warning -Message "Send-Gauge error [${metric}]: $_" `
            -ErrorAction SilentlyContinue
    }
}


function Read-Counter {
    <#
    .SYNOPSIS
        Read one Windows Performance Counter.
        Returns $null if the counter is unavailable (e.g. w3wp not running).
    #>
    param(
        [string]$category,
        [string]$counter,
        [string]$instance = $null
    )
    try {
        if ($instance) {
            $pc = New-Object System.Diagnostics.PerformanceCounter($category, $counter, $instance, $true)
        } else {
            $pc = New-Object System.Diagnostics.PerformanceCounter($category, $counter, "", $true)
        }
        $pc.NextValue() | Out-Null   # first call always returns 0 — discard it
        Start-Sleep -Milliseconds 100
        $val = $pc.NextValue()
        $pc.Close()
        $pc.Dispose()
        return $val
    } catch {
        return $null
    }
}


function Read-Counter-SumAllInstances {
    <#
    .SYNOPSIS
        Enumerate all instances of a multi-instance Performance Counter category
        and return the sum across all instances (excluding _Total / __Total__).
        Returns $null if the category does not exist or has no instances.
    #>
    param(
        [string]$category,
        [string]$counter
    )
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory($category)
        $instances = $cat.GetInstanceNames() | Where-Object { $_ -notmatch '^_+Total_*$' -and $_ -ne '' }
        if (-not $instances) { return $null }

        $total = 0.0
        $found = 0
        foreach ($inst in $instances) {
            try {
                $pc = New-Object System.Diagnostics.PerformanceCounter($category, $counter, $inst, $true)
                $pc.NextValue() | Out-Null
                Start-Sleep -Milliseconds 50
                $val = $pc.NextValue()
                $pc.Close()
                $pc.Dispose()
                $total += $val
                $found++
            } catch {}
        }
        if ($found -gt 0) { return $total }
        return $null
    } catch {
        return $null
    }
}


Write-Host "Datadog IIS metrics collector starting"
Write-Host "Sending to ${statsd}:${port} every ${interval}s"

while ($true) {

    # ── ASP.NET v4 counters ────────────────────────────────────────────────────
    $aspnet = @{
        "aspnet.requests.current"       = @("ASP.NET v4.0.30319", "Requests Current")
        "aspnet.requests.queued"        = @("ASP.NET v4.0.30319", "Requests Queued")
        "aspnet.requests.rejected"      = @("ASP.NET v4.0.30319", "Requests Rejected")
        "aspnet.request.execution_time" = @("ASP.NET v4.0.30319", "Request Execution Time")
        "aspnet.request.wait_time"      = @("ASP.NET v4.0.30319", "Request Wait Time")
        "aspnet.requests.in_queue"      = @("ASP.NET v4.0.30319", "Requests In Native Queue")
    }
    foreach ($m in $aspnet.GetEnumerator()) {
        $val = Read-Counter -category $m.Value[0] -counter $m.Value[1]
        if ($val -ne $null) { Send-Gauge -metric $m.Key -value $val -tags $tags }
    }

    # ── ASP.NET Applications — Requests Executing ───────────────────────────────
    # \ASP.NET Applications(*)\Requests Executing — uses __Total__ instance (always present)
    $appReqExec = Read-Counter -category "ASP.NET Applications" -counter "Requests Executing" -instance "__Total__"
    if ($appReqExec -ne $null) {
        Send-Gauge -metric "aspnet.app.requests_executing" -value $appReqExec -tags $tags
    }

    # ── IIS Web Service counters ───────────────────────────────────────────────
    # _Total means all IIS sites combined
    $iis = @{
        "iis.connections.current" = @("Web Service", "Current Connections")
        "iis.requests.get"        = @("Web Service", "Total Get Requests")
        "iis.requests.post"       = @("Web Service", "Total Post Requests")
    }
    foreach ($m in $iis.GetEnumerator()) {
        $val = Read-Counter -category $m.Value[0] -counter $m.Value[1] -instance "_Total"
        if ($val -ne $null) { Send-Gauge -metric $m.Key -value $val -tags $tags }
    }

    # ── w3wp IIS worker process ────────────────────────────────────────────────
    # There can be multiple w3wp instances (one per app pool).
    # We sum all of them: w3wp, w3wp#1, w3wp#2 ... w3wp#7
    $cpu_total = 0.0
    $mem_total = 0.0
    $found     = 0
    for ($i = 0; $i -le 7; $i++) {
        $inst = if ($i -eq 0) { "w3wp" } else { "w3wp#$i" }
        $cpu  = Read-Counter -category "Process" -counter "% Processor Time" -instance $inst
        $mem  = Read-Counter -category "Process" -counter "Working Set"       -instance $inst
        if ($cpu -ne $null) {
            $cpu_total += $cpu
            $mem_total += $mem
            $found++
        }
    }
    if ($found -gt 0) {
        Send-Gauge -metric "w3wp.cpu_pct"      -value $cpu_total -tags $tags
        Send-Gauge -metric "w3wp.memory_bytes" -value $mem_total -tags $tags
    }

    # ── W3SVC_W3WP — Active Requests per app pool ─────────────────────────────
    # \W3SVC_W3WP(*)\Active Requests — summed across all app pool worker processes
    # Sends 0 when no instances are active (idle server) — valid metric value
    $w3ActiveReq = Read-Counter-SumAllInstances -category "W3SVC_W3WP" -counter "Active Requests"
    Send-Gauge -metric "w3wp.active_requests" -value ([double]($w3ActiveReq ?? 0)) -tags $tags

    Start-Sleep -Seconds $interval
}
