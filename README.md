# KarSession

> A persistent tmux session manager for Bash — run any command in a tracked, detachable session and come back to it whenever you want.

Built by **Karim Refay**

---

## The Problem It Solves

You run a long tool — a port scan, a password cracker, a listener — and you need to:
- Keep it running after you close the terminal
- Come back and check its output later
- Run several tools in parallel without losing track of any of them
- Know whether each one succeeded, failed, or is still going

KarSession does all of that. Every command you launch gets its own named tmux session with full state tracking, persistent logs, and an interactive dashboard to manage everything from one place.

---

## Two Ways to Use It

### Mode 1 — CLI: wrap any one-off command

```bash
# Run a command in a managed session
./karsession.sh run "nmap -sV 192.168.1.1" --name nmap-scan

# Session starts in the background. You get back the ID immediately.
# [+] Session started: nmap-scan → karsession_1728317234_1234
# [*] Session ID: karsession_1728317234_1234
# [*] Attach:     karsession.sh attach karsession_1728317234_1234
# [*] Menu:       karsession.sh menu

# Start more jobs
./karsession.sh run "hashcat -m 1000 hash.txt rockyou.txt" --name crack
./karsession.sh run "sliver-server" --name sliver-c2

# Check what's running
./karsession.sh list

# Jump into the interactive dashboard
./karsession.sh menu
```

### Mode 2 — Library: source it inside your own script

```bash
#!/usr/bin/env bash
source /path/to/karsession.sh

# Every call to run_in_session launches a separate tracked session
S1=$(run_in_session "nmap-scan"   "nmap -sV 192.168.1.1")
S2=$(run_in_session "hash-crack"  "hashcat -m 1000 hash.txt rockyou.txt")
S3=$(run_in_session "web-enum"    "gobuster dir -u http://target -w wordlist.txt")

# All three are running simultaneously. Open the dashboard to manage them.
sessions_menu

# Or wait for one programmatically
wait_for_completion "$S1" 300   # returns 0=success 1=failed 124=timeout
```

---

## Install

```bash
git clone https://github.com/YOUR_USERNAME/KarSession
cd KarSession
chmod +x karsession.sh
```

**Requirement:** `tmux` must be installed.

```bash
sudo apt install tmux       # Debian/Ubuntu/Kali
sudo dnf install tmux       # Fedora/RHEL
brew install tmux           # macOS
```

---

## CLI Reference

```
karsession.sh run <"command"> [OPTIONS]
karsession.sh list
karsession.sh attach  <# | session-id>
karsession.sh info    <# | session-id>
karsession.sh log     <# | session-id> [--lines N]
karsession.sh status  <# | session-id>
karsession.sh kill    <# | session-id>
karsession.sh clean
karsession.sh menu
karsession.sh --help
karsession.sh --version
```

| Command | What it does |
|---|---|
| `run` | Start a command in a new tracked session |
| `list` | Show all active sessions with status |
| `attach` | Enter a session (Ctrl+B then D to detach) |
| `info` | Full metadata: label, status, exit code, timestamps, log path |
| `log` | Print last N lines of the session's output log |
| `status` | Print status; exits 0 if SUCCESS, 1 otherwise |
| `kill` | Terminate a session and mark it KILLED |
| `clean` | Delete metadata and logs for finished sessions |
| `menu` | Interactive dashboard — attach / info / log / kill / clean |

### `run` options

| Flag | Default | Description |
|---|---|---|
| `--name NAME` | `job` | Human-readable label shown in the menu |
| `--wait` | off | Block until the command finishes |
| `--timeout N` | `300` | Seconds before `--wait` gives up (exit 124) |

---

## Interactive Menu

`karsession.sh menu` opens a live dashboard:

```
══════════════════════════════════════════
 KarSession — Active Jobs
══════════════════════════════════════════

  #    Label                  Status      Started
  1)   nmap-scan              RUNNING     2026-10-08 14:23
  2)   hash-crack             SUCCESS     2026-10-08 14:21
  3)   sliver-c2              RUNNING     2026-10-08 14:20

  a) Attach   i) Info   l) Log   k) Kill   c) Clean   r) Refresh   q) Quit

  >
```

Sessions can be referenced by **number** (`1`, `2`) or by their full ID.

---

## Library API

```bash
source /path/to/karsession.sh
```

| Function | Description |
|---|---|
| `run_in_session NAME CMD` | Start job; prints session ID on stdout |
| `list_sessions` | Print active session IDs (one per line) |
| `session_count` | Print integer count of active sessions |
| `session_status ID` | Print status string |
| `session_exit_code ID` | Print exit code (available once done) |
| `session_info ID` | Print full metadata table |
| `attach_session ID` | tmux attach |
| `end_session ID` | Kill + mark KILLED |
| `capture_session_output ID [N]` | Last N lines of live or logged output |
| `is_session_done ID` | Returns 0 if command has finished |
| `wait_for_completion ID [TIMEOUT]` | Block until done — 0/1/124/125 |
| `sessions_menu` | Open interactive TUI dashboard |
| `cleanup_session ID` | Remove metadata for one finished job |
| `cleanup_finished_sessions` | Remove all finished jobs' metadata |

### Return codes for `wait_for_completion`

| Code | Meaning |
|---|---|
| `0` | SUCCESS — command exited 0 |
| `1` | FAILED — command exited non-zero |
| `124` | TIMEOUT — exceeded the timeout |
| `125` | UNKNOWN / KILLED |

---

## Session States

```
CREATED  →  RUNNING  →  SUCCESS
                     →  FAILED
                     →  TIMEOUT   (wait_for_completion exceeded)
                     →  KILLED    (end_session called)
```

---

## Session Logs

Every job writes a full log automatically:

```
$KARSESSION_STATE_DIR/logs/<session-id>.log
```

The log includes the command, all output, finish time, and exit code. It survives after the session ends.

```bash
# View log for session #2
karsession.sh log 2

# Or tail it live from another terminal
tail -f /tmp/karsession/logs/karsession_1728317234_1234.log
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SESSION_PREFIX` | `karsession` | Prefix for tmux session names |
| `KARSESSION_STATE_DIR` | `/tmp/karsession` | Root directory for metadata and logs |

```bash
# Example: use a custom state dir so logs survive reboot
export KARSESSION_STATE_DIR="$HOME/.karsession"
source karsession.sh
```

---

## Example: Parallel Recon Script

```bash
#!/usr/bin/env bash
source /path/to/karsession.sh

TARGET="192.168.1.0/24"

echo "[*] Starting parallel recon on $TARGET"

S1=$(run_in_session "port-scan"    "nmap -sV -T4 $TARGET -oN nmap_out.txt")
S2=$(run_in_session "ping-sweep"   "nmap -sn $TARGET")
S3=$(run_in_session "vuln-scan"    "nmap --script vuln $TARGET")

echo "[*] Three scans running. Opening dashboard..."
sessions_menu

# After closing the menu, check results
echo "[*] Port scan status: $(session_status "$S1")"
echo "[*] Ping sweep status: $(session_status "$S2")"
```

---

## Design Notes

- Each job runs inside a **separate tmux session** named `karsession_<epoch>_<random>`.
- The runner script is written to a temp file and executed inside the pane — the command string is never embedded directly in the `tmux` command line, avoiding shell quoting issues.
- State is persisted to `$KARSESSION_STATE_DIR/jobs/<id>/` so status survives terminal disconnects.
- `wait_for_completion` watches the `done` sentinel file, not `tmux has-session`, so it correctly distinguishes a finished job from a killed one.
- The library detects whether logging functions (`log_info`, `log_error`, etc.) are already defined by a parent script, and only defines its own if they are absent — so it integrates cleanly into any existing tool.

---

## Requirements

- Bash 5+
- tmux 2.6+
- Linux (tested on Kali Linux, Ubuntu 22.04+)

---

## License

MIT
