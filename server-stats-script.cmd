#!/usr/bin/env bash
@# 2>nul & @goto WINDOWS_BLOCK
# ======================================================================
# server-stats-script.sh — Server performance analyser (Linux + macOS)
# Usage: bash server-stats-script.sh
#        bash server-stats-script.sh --html report.html
# ======================================================================

set -euo pipefail

# ── HTML Export Setup ──────────────────────────────────────────────────────
HTML_FILE=""
TEMP_LOG=""
if [[ "${1:-}" == "--html" && -n "${2:-}" ]]; then
    HTML_FILE="$2"
    TEMP_LOG=$(mktemp)
    exec 3>&1  # Save original terminal output to File Descriptor 3
    exec > >(tee "$TEMP_LOG") 2>&1
fi

OS="$(uname -s)"   # "Linux" | "Darwin"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
hr()     { printf '%80s\n' '' | tr ' ' '-'; }
header() { echo -e "\n${BOLD}${CYAN}$1${RESET}"; hr; }
label()  { printf "  ${BOLD}%-28s${RESET}" "$1"; }

pct_colour() {
    local pct="${1%%.*}"
    if   (( pct >= 85 )); then echo -e "${RED}${1}%${RESET}"
    elif (( pct >= 60 )); then echo -e "${YELLOW}${1}%${RESET}"
    else                       echo -e "${GREEN}${1}%${RESET}"
    fi
}

to_gib() { awk -v n="$1" 'BEGIN {printf "%8.2f GiB", n / 1073741824}'; }

# ── Banner ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Server Performance Stats${RESET}"
echo    "  Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo    "  Hostname  : $(hostname -f 2>/dev/null || hostname)"

# ===================
# SYSTEM INFORMATION
# ===================
header "SYSTEM INFORMATION"

case "$OS" in
  Linux)
    if [[ -f /etc/os-release ]]; then
        os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")
    else
        os_name="$(uname -o 2>/dev/null || uname -s)"
    fi
    cpu_cores=$(nproc)
    ;;
  Darwin)
    os_name="$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    cpu_cores=$(sysctl -n hw.logicalcpu)
    ;;
esac

label "OS Version:";    echo "$os_name"
label "Kernel:";        echo "$(uname -r)"
label "Architecture:";  echo "$(uname -m)"
label "CPU Cores:";     echo "$cpu_cores logical"
label "Uptime:";        uptime 2>/dev/null | sed 's/.*up /up /' | sed 's/, *[0-9]* user.*//'

# Load average
if [[ -r /proc/loadavg ]]; then
    read -r load1 load5 load15 _ < /proc/loadavg
else
    loads=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
    read -r load1 load5 load15 <<< "$loads"
fi
label "Load Average:";  echo "${load1} (1m)  ${load5} (5m)  ${load15} (15m)"

logged_in=$(who 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
label "Logged-in Users:"; echo "${logged_in:-none}"

# ===================
# CPU USAGE
# ===================
header "CPU USAGE"

case "$OS" in
  Linux)
    snap1=$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
    sleep 0.5
    snap2=$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
    cpu_pct=$(awk -v s1="$snap1" -v s2="$snap2" 'BEGIN {
        n=split(s1,a," "); split(s2,b," ")
        dt=0
        for(i=1;i<=n;i++) dt += b[i]-a[i]
        di=b[4]-a[4]
        printf "%.1f", (dt>0) ? (dt-di)/dt*100 : 0
    }')
    ;;
  Darwin)
    # top -l 2: discard boot-average.
    # (3-arg match(s,r,arr) is a GNU awk extension, BSD awk does not support it.)
    cpu_idle=$(top -l 2 -n 0 2>/dev/null \
        | awk '/^CPU usage/ {line=$0} END {
            n = split(line, a, " ")
            for (i=1; i<=n; i++) {
                if (a[i] == "idle") {
                    val = a[i-1]; gsub(/%/, "", val); print val+0; exit
                }
            }
        }')
    cpu_pct=$(awk -v idle="${cpu_idle:-100}" 'BEGIN {printf "%.1f", 100 - idle}')
    ;;
esac

label "Total CPU Usage:"; echo "$(pct_colour "${cpu_pct:-0.0}")  (${cpu_cores} logical cores)"

# ===================
# MEMORY USAGE
# ===================
header "MEMORY USAGE"

case "$OS" in
  Linux)
    read -r mem_total mem_used mem_free mem_avail \
        < <(free -b | awk '/^Mem:/ {
                avail = (NF >= 7) ? $7 : $4
                print $2, $3, $4, avail
            }')
    ;;
  Darwin)
    mem_total=$(sysctl -n hw.memsize)
    page_size=$(sysctl -n hw.pagesize)
    vm=$(vm_stat 2>/dev/null)
    read -r pages_free pages_active pages_wired pages_compressed \
              pages_inactive pages_purgeable \
        < <(awk -F'[: ]+' '
                /Pages free/                   {f=$NF}
                /Pages active/                 {a=$NF}
                /Pages wired down/             {w=$NF}
                /Pages occupied by compressor/ {c=$NF}
                /Pages inactive/               {i=$NF}
                /Pages purgeable/              {p=$NF}
                END {
                    gsub(/\./,"",f); gsub(/\./,"",a); gsub(/\./,"",w)
                    gsub(/\./,"",c); gsub(/\./,"",i); gsub(/\./,"",p)
                    print f+0, a+0, w+0, c+0, i+0, p+0
                }' <<< "$vm")

    mem_used=$(( (pages_active + pages_wired + pages_compressed) * page_size ))
    mem_free=$(( pages_free * page_size ))
    mem_avail=$(( (pages_free + pages_inactive + pages_purgeable) * page_size ))
    ;;
esac

mem_used_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN {printf "%.1f", (u/t)*100}')
mem_free_pct=$(awk -v f="$mem_free" -v t="$mem_total" 'BEGIN {printf "%.1f", (f/t)*100}')

label "Total:";     echo "$(to_gib "$mem_total")"
label "Used:";      echo "$(to_gib "$mem_used")  ($(pct_colour "$mem_used_pct"))"
label "Free:";      echo "$(to_gib "$mem_free")  (${mem_free_pct}%)"
label "Available:"; echo "$(to_gib "$mem_avail")"

case "$OS" in
  Linux)
    read -r sw_total sw_used _ < <(free -b | awk '/^Swap:/ {print $2,$3,$4}')
    ;;
  Darwin)
    swap_line=$(sysctl -n vm.swapusage 2>/dev/null || echo "")
    sw_total=0; sw_used=0
    read -r sw_total sw_used < <(echo "$swap_line" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i == "total" || $i == "used") {
                val = $(i+2)
                mult = (val ~ /G$/) ? 1073741824 : 1048576
                gsub(/[MG]/, "", val)
                if ($i == "total") t = val * mult
                else               u = val * mult
            }
        }
        print t+0, u+0
    }') || true
    ;;
esac

if (( ${sw_total:-0} > 0 )); then
    sw_pct=$(awk -v u="$sw_used" -v t="$sw_total" 'BEGIN {printf "%.1f", (u/t)*100}')
    label "Swap Used:"; echo "$(to_gib "$sw_used") / $(to_gib "$sw_total")  ($(pct_colour "$sw_pct"))"
else
    label "Swap:"; echo "No swap configured"
fi

# ===================
# DISK USAGE
# ===================
header "DISK USAGE"

printf "  ${BOLD}%-20s %8s %8s %8s %6s  %-s${RESET}\n" \
    "Filesystem" "Size" "Used" "Avail" "Use%" "Mounted on"
hr

case "$OS" in
  Linux)  df_flags="-h" ;;
  Darwin) df_flags="-H" ;;
esac

df $df_flags 2>/dev/null \
    | awk -v RED="$RED" -v YELLOW="$YELLOW" -v GREEN="$GREEN" -v RESET="$RESET" '
        NR > 1 &&
        $1 !~ /^(devfs|map|tmpfs|overlay|none|\/dev\/loop)/ &&
        $NF !~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/ {
            pct = $5 + 0
            colour = (pct >= 85) ? RED : (pct >= 60) ? YELLOW : GREEN
            printf "  %-20s %8s %8s %8s %s%5d%%%s  %-s\n",
                $1, $2, $3, $4, colour, pct, RESET, $NF
        }'

# ===================
# TOP 5 PROCESSES
# ===================
header "TOP 5 PROCESSES -- CPU"
printf "  ${BOLD}%7s  %-12s  %6s  %6s  %-s${RESET}\n" "PID" "USER" "%CPU" "%MEM" "COMMAND"
hr
# pipefail + head -5 causes SIGPIPE on upstream processes; || true absorbs it
{ ps aux 2>/dev/null \
    | tail -n +2 \
    | sort -k3 -rn \
    | awk '{cmd=$11; for(i=12;i<=NF;i++) cmd=cmd" "$i; if(length(cmd)>60) cmd=substr(cmd,1,57)"..."; printf "  %7s  %-12s  %6s  %6s  %s\n", $2,$1,$3,$4,cmd}' \
    | head -5; } || true

header "TOP 5 PROCESSES -- MEMORY"
printf "  ${BOLD}%7s  %-12s  %6s  %6s  %-s${RESET}\n" "PID" "USER" "%MEM" "%CPU" "COMMAND"
hr
{ ps aux 2>/dev/null \
    | tail -n +2 \
    | sort -k4 -rn \
    | awk '{cmd=$11; for(i=12;i<=NF;i++) cmd=cmd" "$i; if(length(cmd)>60) cmd=substr(cmd,1,57)"..."; printf "  %7s  %-12s  %6s  %6s  %s\n", $2,$1,$4,$3,cmd}' \
    | head -5; } || true

# ===================
# FAILED LOGIN ATTEMPTS
# ===================
header "FAILED LOGIN ATTEMPTS (last 24 h)"

case "$OS" in
  Linux)
    if command -v journalctl &>/dev/null; then
        fail_count=$(journalctl -u sshd.service -u ssh.service \
            --since "24 hours ago" 2>/dev/null \
            | grep -c "Failed password") || fail_count=0
        label "SSH Failed Logins:"; echo "$fail_count"
        if (( fail_count > 0 )); then
            echo -e "\n  ${BOLD}Top offending IPs:${RESET}"
            journalctl -u sshd.service -u ssh.service \
                --since "24 hours ago" 2>/dev/null \
                | grep "Failed password" \
                | grep -oE 'from [0-9.]+' \
                | awk '{print $2}' \
                | sort | uniq -c | sort -rn | head -5 \
                | awk '{printf "    %-6s attempts  from %s\n", $1, $2}' || true
        fi
    elif [[ -f /var/log/auth.log ]]; then
        fail_count=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null) \
            || fail_count=0
        label "SSH Failed Logins:"; echo "$fail_count"
    else
        label "Failed Logins:"; echo "Unavailable (no journald or auth.log)"
    fi
    ;;
  Darwin)
    if [[ $EUID -eq 0 ]]; then
        fail_count=$(log show --predicate 'eventMessage contains "Failed password"' \
            --last 24h 2>/dev/null | grep -c "Failed password") || fail_count=0
        label "SSH Failed Logins:"; echo "$fail_count"
    elif [[ -f /var/log/system.log ]]; then
        fail_count=$(grep -c "Failed password" /var/log/system.log 2>/dev/null) \
            || fail_count=0
        label "SSH Failed Logins (~):"; echo "$fail_count  (run with sudo for full 24h log)"
    else
        label "SSH Failed Logins:"; echo "Run with: sudo bash server-stats.sh"
    fi
    ;;
esac

echo ""
hr
echo -e "  ${BOLD}Done.${RESET}  (sudo recommended for complete login-failure data)"

# ===================
# HTML GENERATION
# ===================
if [[ -n "$HTML_FILE" ]]; then
    sleep 0.5

    {
        cat <<'HTMLHEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Stats Report</title>
    <style>
        body {
            background-color: #1e1e1e;
            color: #d4d4d4;
            font-family: 'Courier New', Courier, monospace;
            padding: 20px;
            margin: 0;
        }
        pre {
            font-size: 14px;
            line-height: 1.5;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
    </style>
</head>
<body>
<pre>
HTMLHEADER

        sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$TEMP_LOG"

        printf '\n</pre>\n</body>\n</html>\n'
    } > "$HTML_FILE"

    rm -f "$TEMP_LOG"

    echo -e "\n${GREEN}Report saved to ${BOLD}$HTML_FILE${RESET}" >&3

    exec 3>&-
fi
exit 0

:WINDOWS_BLOCK
@echo off
setlocal

set "TEMP_PS=%TEMP%\server-stats-temp.ps1"

:: Extract the PowerShell section from this file and save it to a temp file
powershell.exe -ExecutionPolicy Bypass -NoLogo -Command "$l=Get-Content '%~f0';$r=0;for($i=0;$i -lt $l.count;$i++){if($l[$i] -match '^# PS_START'){$r=$i+1;break}};$l[$r..($l.count-1)] | Set-Content -Encoding UTF8 -Path '%TEMP_PS%'"

:: Execute the temp PowerShell script
powershell.exe -ExecutionPolicy Bypass -NoLogo -File "%TEMP_PS%" %1 %2

:: Clean up the temp file
del "%TEMP_PS%" >nul 2>&1

echo.
pause
endlocal
exit /b

# PS_START
# ======================================================================
# WINDOWS SECTION (PowerShell)
# ======================================================================

param(
    [string]$HtmlFile = ""
)

# Override $HtmlFile if called from Batch with --html
if ($args.Count -ge 2 -and $args[0] -eq "--html") {
    $HtmlFile = $args[1]
}

# ── Colours ──────────────────────────────────────────────────────────
 $RED    = [char]27 + "[0;31m"; $YELLOW = [char]27 + "[1;33m"; $GREEN = [char]27 + "[0;32m"
 $CYAN   = [char]27 + "[0;36m"; $BOLD   = [char]27 + "[1m";    $RESET = [char]27 + "[0m"

# ── Helpers ──────────────────────────────────────────────────────────
 $script:PendingLabel = ""
 $script:PendingLabelClean = ""

function hr         { log ("-" * 80) }
function header($t) { log "`n${BOLD}${CYAN}${t}${RESET}"; hr }

function label($l) {
    $script:PendingLabel = "  ${BOLD}$($l.PadRight(28))${RESET}"
    $script:PendingLabelClean = "  $($l.PadRight(28))"
}

function pct_colour($p) {
    $val = [int]([math]::Truncate($p))
    if     ($val -ge 85) { return "${RED}${p}%${RESET}" }
    elseif ($val -ge 60) { return "${YELLOW}${p}%${RESET}" }
    else                 { return "${GREEN}${p}%${RESET}" }
}

function to_gib($bytes) { return "{0:N2} GiB" -f ($bytes / 1GB) }

# ── Capture Output for HTML ─────────────────────────────────────────
 $OutputLines = [System.Collections.ArrayList]::new()

function log($text) {
    $fullLine = "$script:PendingLabel$text"
    $fullLineClean = "$script:PendingLabelClean$text"
    
    $script:PendingLabel = ""
    $script:PendingLabelClean = ""
    
    Write-Host $fullLine
    
    if ($HtmlFile -ne "") {
        # Bulletproof ANSI stripping for the HTML file
        $clean = [regex]::Replace($fullLineClean, '\x1b\[[0-9;]*[a-zA-Z]', '')
        [void]$OutputLines.Add($clean)
    }
}

# ── Banner ───────────────────────────────────────────────────────────
log "`n${BOLD}Server Performance Stats${RESET}"
log "  Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
log "  Hostname  : $env:COMPUTERNAME"

# ===================
# SYSTEM INFORMATION
# ===================
header "SYSTEM INFORMATION"

 $os     = Get-CimInstance Win32_OperatingSystem
 $uptime = (Get-Date) - $os.LastBootUpTime

label "OS Version:";     log "$($os.Caption) $($os.Version)"
label "Architecture:";   log $env:PROCESSOR_ARCHITECTURE
label "CPU Cores:";      log "$($env:NUMBER_OF_PROCESSORS) logical"
label "Uptime:";         log "up $($uptime.Days) days, $($uptime.Hours):$($uptime.Minutes.ToString('00'))"
label "Load Average:";   log "N/A (Windows uses Processor Queue Length)"

 $users = query user 2>$null | Select-Object -Skip 1 |
    ForEach-Object { ($_ -split '\s+')[1] } |
    Where-Object { $_ -ne '' -and $_ -ne '>' } |
    Sort-Object -Unique
label "Logged-in Users:"; log ($users -join ' ')

# ===================
# CPU USAGE
# ===================
header "CPU USAGE"

 $cpu1 = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2
 $pct  = [math]::Round(($cpu1 | Select-Object -Last 1).CounterSamples[0].CookedValue, 1)

label "Total CPU Usage:"
log "$(pct_colour $pct)  ($($env:NUMBER_OF_PROCESSORS) logical cores)"

# ===================
# MEMORY USAGE
# ===================
header "MEMORY USAGE"

 $mem_total = $os.TotalVisibleMemorySize * 1KB
 $mem_free  = $os.FreePhysicalMemory * 1KB
 $mem_used  = $mem_total - $mem_free
 $mem_avail = $mem_free

 $mem_used_pct = [math]::Round(($mem_used / $mem_total) * 100, 1)
 $mem_free_pct = [math]::Round(($mem_free / $mem_total) * 100, 1)

label "Total:";     log "$(to_gib $mem_total)"
label "Used:";      log "$(to_gib $mem_used)  ($(pct_colour $mem_used_pct))"
label "Free:";      log "$(to_gib $mem_free)  ($mem_free_pct%)"
label "Available:"; log "$(to_gib $mem_avail)"

 $swap = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
if ($swap) {
    $sw_used  = $swap.CurrentUsage * 1MB
    $sw_total = $swap.AllocatedBaseSize * 1MB
    $sw_pct   = [math]::Round(($sw_used / $sw_total) * 100, 1)
    label "Swap Used:"; log "$(to_gib $sw_used) / $(to_gib $sw_total)  ($(pct_colour $sw_pct))"
} else {
    label "Swap:"; log "No pagefile configured"
}

# ===================
# DISK USAGE
# ===================
header "DISK USAGE"

log ("  ${BOLD}{0,-6} {1,12} {2,12} {3,12} {4,6}  {5}${RESET}" -f "FS", "Size", "Used", "Avail", "Use%", "Mounted on")
hr

Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $d_total  = $_.Size
    $d_free   = $_.FreeSpace
    $d_used   = $d_total - $d_free
    $d_pct    = [math]::Round(($d_used / $d_total) * 100, 1)
    $d_letter = $_.DeviceID
    $d_name   = if ($_.VolumeName) { $_.VolumeName } else { "" }

    $sizeStr  = to_gib $d_total
    $usedStr  = to_gib $d_used
    $availStr = to_gib $d_free
    $pctStr   = "$d_pct%"

    $baseLine = "  {0,-6} {1,12} {2,12} {3,12} {4,6}  {5}" -f $d_letter, $sizeStr, $usedStr, $availStr, $pctStr, $d_name
    
    if ($d_pct -ge 85) { $c = $RED } elseif ($d_pct -ge 60) { $c = $YELLOW } else { $c = $GREEN }
    $colouredLine = $baseLine -replace [regex]::Escape($pctStr), "$c$pctStr$RESET"
    
    log $colouredLine
}

# ===================
# TOP 5 PROCESSES
# ===================
header "TOP 5 PROCESSES -- CPU"
log ("  ${BOLD}{0,7}  {1,-12}  {2,10}  {3,6}  {4}${RESET}" -f "PID", "USER", "CPU (s)", "%MEM", "COMMAND")
hr

Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
    $cpu_p = [math]::Round($_.CPU, 1)
    $mem_p = [math]::Round(($_.WorkingSet64 / $mem_total) * 100, 1)
    $cmd   = $_.Path
    if (!$cmd) { $cmd = $_.ProcessName }
    if ($cmd.Length -gt 60) { $cmd = $cmd.Substring(0, 57) + "..." }
    $owner = if ($_.UserName) { $_.UserName.Split('\')[-1] } else { $env:USERNAME }
    log ("  {0,7}  {1,-12}  {2,10}  {3,6}  {4}" -f $_.Id, $owner, $cpu_p, $mem_p, $cmd)
}

header "TOP 5 PROCESSES -- MEMORY"
log ("  ${BOLD}{0,7}  {1,-12}  {2,6}  {3,10}  {4}${RESET}" -f "PID", "USER", "%MEM", "CPU (s)", "COMMAND")
hr

Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
    $cpu_p = [math]::Round($_.CPU, 1)
    $mem_p = [math]::Round(($_.WorkingSet64 / $mem_total) * 100, 1)
    $cmd   = $_.Path
    if (!$cmd) { $cmd = $_.ProcessName }
    if ($cmd.Length -gt 60) { $cmd = $cmd.Substring(0, 57) + "..." }
    $owner = if ($_.UserName) { $_.UserName.Split('\')[-1] } else { $env:USERNAME }
    log ("  {0,7}  {1,-12}  {2,6}  {3,10}  {4}" -f $_.Id, $owner, $mem_p, $cpu_p, $cmd)
}

# ===================
# FAILED LOGIN ATTEMPTS
# ===================
header "FAILED LOGIN ATTEMPTS (last 24 h)"

try {
    $events     = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddDays(-1)} -ErrorAction Stop
    $fail_count = $events.Count
    label "Failed Logins:"; log $fail_count

    if ($fail_count -gt 0) {
        log "`n  ${BOLD}Top offending IPs:${RESET}"
        $events | ForEach-Object {
            $xml = [xml]$_.ToXml()
            $ip  = $xml.Event.EventData.Data |
                Where-Object { $_.Name -eq 'IpAddress' } |
                Select-Object -ExpandProperty '#text'
            if ($ip -and $ip -ne "-" -and $ip -ne "::1") { $ip }
        } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
            log ("    {0,-6} attempts  from {1}" -f $_.Count, $_.Name)
        }
    }
} catch {
    label "Failed Logins:"; log "0 (or run as Admin to read Security log)"
}

log ""
hr
log "  ${BOLD}Done.${RESET}  (Admin recommended for complete login-failure data)"

# ── HTML Generation ──────────────────────────────────────────────────
if ($HtmlFile -ne "") {
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Stats Report</title>
    <style>
        body { background-color: #1e1e1e; color: #d4d4d4; font-family: 'Courier New', Courier, monospace; padding: 20px; margin: 0; }
        pre  { font-size: 14px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; }
    </style>
</head>
<body>
<pre>
 $($OutputLines -join "`n")
</pre>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($HtmlFile, $html)
    Write-Host "`n${GREEN}Report saved to ${BOLD}$HtmlFile${RESET}" -ForegroundColor Green
}