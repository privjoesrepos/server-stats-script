#!/usr/bin/env bash
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
    # Wait briefly for tee to finish flushing the buffer to the temp file
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

        # Strip ANSI color codes from the temp log and include in HTML
        sed -E $'s/\x1b\\[[0-9;]*[mGKH]//g' "$TEMP_LOG"

        printf '\n</pre>\n</body>\n</html>\n'
    } > "$HTML_FILE"

    # Clean up the temp file
    rm -f "$TEMP_LOG"

    echo -e "\n${GREEN}Report saved to ${BOLD}$HTML_FILE${RESET}" >&3
    
    # Close FD 3
    exec 3>&-
fi