# server-stats-script.sh

![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-blue)

A lightweight, dependency-free Bash script that analyses core server performance metrics at a glance. Runs on any Linux distribution or macOS machine — no package installs required.

---

## Features

| Category | Metric |
|---|---|
| **System** | OS version, kernel, architecture, uptime, load average, logged-in users |
| **CPU** | Total usage % (live delta sample), logical core count |
| **Memory** | Total / used / free / available in GiB with usage % |
| **Swap** | Used vs total with usage % |
| **Disk** | Per-filesystem size, used, available, usage % (pseudo-fs filtered) |
| **Processes** | Top 5 by CPU, top 5 by memory (commands truncated to 60 chars) |
| **Security** | Failed SSH login attempts in the last 24 hours + top offending IPs |
| **Export** | Save reports as styled HTML files for archiving or emailing |

All percentage values are colour-coded: 🟢 < 60% · 🟡 60–84% · 🔴 ≥ 85%

---

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Ubuntu / Debian | ✅ Supported | Tested on Ubuntu 22.04, 24.04 |
| RHEL / Amazon Linux | ✅ Supported | Requires `bash` |
| macOS (Catalina+) | ✅ Supported | Tested on macOS 26 (arm64) |
| WSL2 | ⚠️ Mostly works | `who` and login-failure sections may vary |
| FreeBSD / OpenBSD | ❌ Not supported | `sysctl` key names differ |

> **Requires `bash`** — do not run with `sh` or `dash`. The shebang (`#!/usr/bin/env bash`) handles this automatically when executed directly.

---

## Prerequisites

No external dependencies. The following tools are used and present by default on all supported platforms:

- `bash`
- `awk`, `grep`, `ps`, `df`, `who`, `date`, `sort`
- **Linux only:** `free`, `/proc/stat`, `/proc/loadavg`, `journalctl` (or `/var/log/auth.log`)
- **macOS only:** `sysctl`, `vm_stat`, `sw_vers`, `top`, `log`

---

## Installation

```bash
git clone https://github.com/privjoesrepos/server-stats-script.git
cd server-stats-script
chmod +x server-stats-script.sh
```

---

## Usage

```bash
# Standard run (coloured terminal output)
./server-stats-script.sh

# Full output including complete SSH login-failure data
sudo ./server-stats-script.sh

# Export report to a styled HTML file (change the path of the file as you wish) 
./server-stats-script.sh --html report.html

# Full output including complete SSH login-failure data
sudo ./server-stats-script.sh --html /var/www/html/server-stats.html
```

---

## How It Works

### CPU measurement

Rather than reading a single `top` snapshot (which reflects a lifetime average), the script samples `/proc/stat` twice with a 0.5-second interval and computes:

```
cpu% = (delta_total - delta_idle) / delta_total × 100
```

On macOS, `top -l 2 -n 0` is used — the second sample gives the live-interval idle %, avoiding the same boot-average pitfall. The idle value is extracted with a field-split loop rather than `match(s,r,arr)`, which is a GNU awk extension not supported by BSD awk.

### Memory (macOS)

`free` does not exist on macOS. The script uses `vm_stat` page counts × `hw.pagesize`:

- **Used** = (active + wired + compressed) pages × page size
- **Available** = (free + inactive + purgeable) pages × page size

This matches what Activity Monitor reports.

### Disk filtering

On Linux, pseudo-filesystems (`tmpfs`, `devtmpfs`, `overlay`, `/dev/loop*`) are excluded by matching against the source column. On macOS, APFS role volumes (`/System/Volumes/VM`, `Preboot`, `Update`, `xarts`, `iSCPreboot`, `Hardware`) and automount entries (`map`) are excluded, while `/System/Volumes/Data` (the main user volume) is kept.

### Process sorting

`ps aux` is piped through `sort -k3 -rn` (CPU) and `sort -k4 -rn` (memory) rather than relying on `ps` sort flags, which differ between GNU and BSD. Commands are truncated to 60 characters to keep output readable.

### Failed login detection

- **Linux (systemd):** `journalctl` filtered to `sshd.service` or `ssh.service` for the last 24 hours
- **Linux (syslog):** falls back to `/var/log/auth.log`
- **macOS:** `log show` with a predicate filter (requires `sudo`); falls back to `/var/log/system.log`

### HTML Export

- When the `--html` flag is passed, the script uses `exec` and `tee` to capture the live terminal output without breaking interactive commands like `top`. At the end of the run, it strips the ANSI colour codes using `sed`, wraps the output in a dark-themed HTML template (mimicking a terminal), and writes it to the specified file.
**Preview:**
![HTML Report Preview](assets/html-preview.png)
