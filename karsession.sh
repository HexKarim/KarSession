#!/usr/bin/env bash
# ==============================================================================
# KarSession — Persistent tmux session manager
#
# Author  : Karim Refay
# Version : 1.0.0
# License : MIT
#
# TWO MODES:
#
#   1. CLI  — wrap any one-off command in a managed tmux session:
#        ./karsession.sh run "nmap -sV 192.168.1.1" --name my-scan
#        ./karsession.sh list
#        ./karsession.sh attach 1
#        ./karsession.sh menu
#
#   2. Library — source inside your own script so every job you launch
#        gets its own persistent, tracked session automatically:
#        source /path/to/karsession.sh
#        SESSION=$(run_in_session "scan"  "nmap -sV 192.168.1.1")
#        SESSION=$(run_in_session "crack" "hashcat -m 1000 hash.txt rockyou.txt")
#        sessions_menu
#
# ==============================================================================

set -uo pipefail

# ==============================================================================
# VERSION
# ==============================================================================

KS_VERSION="1.0.0"

# ==============================================================================
# CONFIGURATION  (all overridable via env vars before sourcing)
# ==============================================================================

SESSION_PREFIX="${SESSION_PREFIX:-karsession}"

KARSESSION_STATE_DIR="${KARSESSION_STATE_DIR:-${TMPDIR:-/tmp}/karsession}"
KARSESSION_JOBS_DIR="$KARSESSION_STATE_DIR/jobs"
KARSESSION_LOGS_DIR="$KARSESSION_STATE_DIR/logs"
KARSESSION_TMP_DIR="$KARSESSION_STATE_DIR/tmp"

mkdir -p \
    "$KARSESSION_JOBS_DIR" \
    "$KARSESSION_LOGS_DIR" \
    "$KARSESSION_TMP_DIR" \
    2>/dev/null || true

# ==============================================================================
# COLORS  (auto-disabled when not a TTY)
# ==============================================================================

if [[ -t 1 ]]; then
    _KS_RED=$'\033[0;31m'
    _KS_GREEN=$'\033[0;32m'
    _KS_YELLOW=$'\033[1;33m'
    _KS_BLUE=$'\033[0;34m'
    _KS_CYAN=$'\033[0;36m'
    _KS_BOLD=$'\033[1m'
    _KS_DIM=$'\033[2m'
    _KS_RESET=$'\033[0m'
else
    _KS_RED='' _KS_GREEN='' _KS_YELLOW=''
    _KS_BLUE='' _KS_CYAN='' _KS_BOLD=''
    _KS_DIM='' _KS_RESET=''
fi

# ==============================================================================
# BUILT-IN LOG FUNCTIONS
# (only defined if not already provided by a parent script)
# ==============================================================================

if ! declare -F log_info >/dev/null 2>&1; then
    log_info()    { printf "${_KS_BLUE}[*]${_KS_RESET} %s\n"    "$1"; }
    log_success() { printf "${_KS_GREEN}[+]${_KS_RESET} %s\n"   "$1"; }
    log_error()   { printf "${_KS_RED}[-]${_KS_RESET} %s\n"     "$1" >&2; }
    log_warn()    { printf "${_KS_YELLOW}[!]${_KS_RESET} %s\n"  "$1"; }
fi

# ==============================================================================
# INTERNAL HELPERS
# ==============================================================================

_ks_meta_dir()   { printf '%s\n'   "$KARSESSION_JOBS_DIR/$1"; }
_ks_meta_file()  { printf '%s/%s'  "$KARSESSION_JOBS_DIR/$1" "$2"; }
_ks_log_file()   { printf '%s/%s.log' "$KARSESSION_LOGS_DIR" "$1"; }
_ks_done_file()  { _ks_meta_file "$1" "done"; }
_ks_status_file(){ _ks_meta_file "$1" "status"; }
_ks_exit_file()  { _ks_meta_file "$1" "exit_code"; }
_ks_pid_file()   { _ks_meta_file "$1" "pid"; }
_ks_cmd_file()   { _ks_meta_file "$1" "command"; }

_ks_timestamp()  { date '+%Y-%m-%d %H:%M:%S'; }
_ks_epoch()      { date '+%s'; }

_ks_safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-120
}

_ks_meta_exists() { [ -d "$(_ks_meta_dir "$1")" ]; }

_ks_write_meta() {
    local SESSION="$1" KEY="$2" VALUE="$3"
    local DIR; DIR="$(_ks_meta_dir "$SESSION")"
    mkdir -p "$DIR" 2>/dev/null || return 1
    printf '%s\n' "$VALUE" > "$DIR/$KEY"
}

_ks_read_meta() {
    local FILE; FILE="$(_ks_meta_file "$1" "$2")"
    [ -f "$FILE" ] || return 1
    cat "$FILE"
}

# Color-code a status string
_ks_status_color() {
    case "$1" in
        RUNNING)  printf "${_KS_CYAN}%s${_KS_RESET}"   "$1" ;;
        SUCCESS)  printf "${_KS_GREEN}%s${_KS_RESET}"  "$1" ;;
        FAILED)   printf "${_KS_RED}%s${_KS_RESET}"    "$1" ;;
        KILLED)   printf "${_KS_YELLOW}%s${_KS_RESET}" "$1" ;;
        TIMEOUT)  printf "${_KS_YELLOW}%s${_KS_RESET}" "$1" ;;
        CREATED)  printf "${_KS_BLUE}%s${_KS_RESET}"   "$1" ;;
        *)        printf "%s" "$1" ;;
    esac
}

# Resolve a user-supplied argument (number OR session ID) to a session name.
# Prints the session name if found, returns 1 if not.
_ks_resolve() {
    local ARG="$1"
    if [[ "$ARG" =~ ^[0-9]+$ ]]; then
        # Numeric — treat as 1-based index into list
        local IDX=$((ARG - 1))
        local -a ALL=()
        while IFS= read -r s; do [[ -n "$s" ]] && ALL+=("$s"); done \
            < <(list_sessions)
        if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#ALL[@]}" ]; then
            printf '%s\n' "${ALL[$IDX]}"
            return 0
        fi
    else
        # Treat as exact session name
        if session_running "$ARG" || _ks_meta_exists "$ARG"; then
            printf '%s\n' "$ARG"
            return 0
        fi
    fi
    log_error "No session found for: $ARG"
    return 1
}

# ==============================================================================
# SESSION STATUS
# ==============================================================================

session_status() {
    local SESSION="$1"
    local STATUS
    STATUS=$(_ks_read_meta "$SESSION" "status" 2>/dev/null)
    if [ -n "$STATUS" ]; then
        printf '%s\n' "$STATUS"; return 0
    fi
    if session_running "$SESSION"; then
        printf 'RUNNING\n'
    else
        printf 'UNKNOWN\n'
    fi
}

session_exit_code() {
    local FILE; FILE="$(_ks_exit_file "$1")"
    [ -f "$FILE" ] || return 1
    cat "$FILE"
}

session_log_file() { printf '%s\n' "$(_ks_log_file "$1")"; }

# ==============================================================================
# RUN A COMMAND IN A NEW TMUX SESSION
# ==============================================================================
#
# Usage:
#   SESSION=$(run_in_session "label" "command string")
#
# Returns the tmux session ID on stdout.
# The label is stored in metadata and shown in the sessions menu.

run_in_session() {
    local NAME="$1"
    local CMD="$2"

    command -v tmux >/dev/null 2>&1 || { log_error "tmux is not installed"; return 1; }
    [ -n "$CMD" ]                   || { log_error "Empty command"; return 1; }

    local SESSION_NAME
    SESSION_NAME="$(_ks_safe_name "${SESSION_PREFIX}_$(_ks_epoch)_$RANDOM")"

    local META_DIR LOG_FILE WRAPPER CMD_FILE
    META_DIR="$(_ks_meta_dir "$SESSION_NAME")"
    LOG_FILE="$(_ks_log_file "$SESSION_NAME")"
    WRAPPER="$KARSESSION_TMP_DIR/${SESSION_NAME}.runner.sh"
    CMD_FILE="$(_ks_cmd_file "$SESSION_NAME")"

    mkdir -p "$META_DIR" "$KARSESSION_TMP_DIR" "$KARSESSION_LOGS_DIR" \
        2>/dev/null || { log_error "Failed to create session directories"; return 1; }

    printf '%s\n' "$CMD" > "$CMD_FILE"

    _ks_write_meta "$SESSION_NAME" "name"          "$NAME"
    _ks_write_meta "$SESSION_NAME" "status"        "CREATED"
    _ks_write_meta "$SESSION_NAME" "created_at"    "$(_ks_timestamp)"
    _ks_write_meta "$SESSION_NAME" "created_epoch" "$(_ks_epoch)"
    _ks_write_meta "$SESSION_NAME" "log_file"      "$LOG_FILE"

    # ----------------------------------------------------------------
    # Runner script — executed INSIDE the tmux pane.
    # Separated from the tmux command line to avoid shell-quoting issues.
    # ----------------------------------------------------------------
    cat > "$WRAPPER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set +e

SESSION_NAME="$1"
META_DIR="$2"
LOG_FILE="$3"
CMD_FILE="$4"

STATUS_FILE="$META_DIR/status"
EXIT_FILE="$META_DIR/exit_code"
DONE_FILE="$META_DIR/done"
PID_FILE="$META_DIR/pid"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
write_status() { printf '%s\n' "$1" > "$STATUS_FILE"; }

write_status "RUNNING"
printf '%s\n' "$$"    > "$PID_FILE"
printf '%s\n' "$(ts)" > "$META_DIR/started_at"

{
    echo "=================================================="
    echo " KarSession Job"
    echo " Session : $SESSION_NAME"
    echo " Started : $(ts)"
    echo "=================================================="
    echo ""
    echo "[COMMAND]"
    cat "$CMD_FILE"
    echo ""
    echo "[OUTPUT]"
} >> "$LOG_FILE"

bash -c "$(cat "$CMD_FILE")" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

printf '%s\n' "$EXIT_CODE" > "$EXIT_FILE"
printf '%s\n' "$(ts)"      > "$META_DIR/finished_at"

if [ "$EXIT_CODE" -eq 0 ]; then write_status "SUCCESS"
else                              write_status "FAILED"
fi

printf '%s\n' "$(ts)" > "$DONE_FILE"

{
    echo ""
    echo "=================================================="
    echo " Finished : $(ts)"
    echo " Exit     : $EXIT_CODE"
    echo " Status   : $(cat "$STATUS_FILE" 2>/dev/null)"
    echo "=================================================="
} >> "$LOG_FILE"

echo ""
echo "[KarSession] Job done — Status: $(cat "$STATUS_FILE" 2>/dev/null)  Exit: $EXIT_CODE"
echo ""
echo "Ctrl+B then D to detach."
echo ""
exec bash
RUNNER_EOF

    chmod 700 "$WRAPPER"

    local WRAPPER_Q SESSION_Q META_Q LOG_Q CMD_Q
    WRAPPER_Q=$(printf '%q' "$WRAPPER")
    SESSION_Q=$(printf '%q' "$SESSION_NAME")
    META_Q=$(printf '%q' "$META_DIR")
    LOG_Q=$(printf '%q' "$LOG_FILE")
    CMD_Q=$(printf '%q' "$CMD_FILE")

    if ! tmux new-session -d -s "$SESSION_NAME" \
        "bash $WRAPPER_Q $SESSION_Q $META_Q $LOG_Q $CMD_Q" \
        >/dev/null 2>&1; then
        _ks_write_meta "$SESSION_NAME" "status" "FAILED"
        rm -f "$WRAPPER" 2>/dev/null
        log_error "tmux failed to create session"
        return 1
    fi

    _ks_write_meta "$SESSION_NAME" "status"     "RUNNING"
    _ks_write_meta "$SESSION_NAME" "started_at" "$(_ks_timestamp)"

    sleep 0.1

    if ! session_running "$SESSION_NAME"; then
        _ks_write_meta "$SESSION_NAME" "status" "FAILED"
        log_error "Session disappeared immediately after start"
        return 1
    fi

    log_success "Session started: ${_KS_BOLD}$NAME${_KS_RESET} → $SESSION_NAME"
    printf '%s\n' "$SESSION_NAME"
    return 0
}

# ==============================================================================
# SESSION LIFECYCLE
# ==============================================================================

list_sessions() {
    tmux list-sessions -F "#{session_name}" 2>/dev/null \
        | grep -E "^${SESSION_PREFIX}_[A-Za-z0-9_.-]+$" || true
}

session_count() {
    local C; C=$(list_sessions | grep -c . 2>/dev/null || true)
    [[ "$C" =~ ^[0-9]+$ ]] && printf '%s\n' "$C" || printf '0\n'
}

session_running() {
    [ -n "$1" ] && tmux has-session -t "$1" 2>/dev/null
}

is_session_done() {
    [ -f "$(_ks_done_file "$1")" ]
}

attach_session() {
    [ -n "$1" ] || return 1
    session_running "$1" || { log_error "Session not running: $1"; return 1; }
    tmux attach-session -t "$1"
}

end_session() {
    [ -n "$1" ] || return 1
    _ks_meta_exists "$1" && {
        _ks_write_meta "$1" "status"      "KILLED"
        _ks_write_meta "$1" "finished_at" "$(_ks_timestamp)"
    }
    session_running "$1" && tmux kill-session -t "$1" 2>/dev/null || true
    return 0
}

stop_session() { end_session "$1"; }   # alias

capture_session_output() {
    local SESSION="$1" LINES="${2:-100}"
    [ -n "$SESSION" ] || return 1
    if session_running "$SESSION"; then
        tmux capture-pane -t "$SESSION" -p -S "-$LINES" 2>/dev/null
        return $?
    fi
    local LOG; LOG="$(_ks_log_file "$SESSION")"
    [ -f "$LOG" ] && tail -n "$LINES" "$LOG"
}

# ==============================================================================
# WAIT FUNCTIONS
# ==============================================================================

wait_for_completion() {
    local SESSION="$1" TIMEOUT="${2:-300}"
    [ -n "$SESSION" ] || return 125
    local ELAPSED=0
    while ! is_session_done "$SESSION"; do
        if ! session_running "$SESSION"; then
            case "$(session_status "$SESSION")" in
                SUCCESS) return 0  ;;
                FAILED)  return 1  ;;
                KILLED)  return 125 ;;
                *)       return 125 ;;
            esac
        fi
        sleep 1; ELAPSED=$((ELAPSED + 1))
        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            _ks_write_meta "$SESSION" "status"          "TIMEOUT"
            _ks_write_meta "$SESSION" "timeout_seconds" "$TIMEOUT"
            log_warn "Timed out after ${TIMEOUT}s — session stays available"
            return 124
        fi
    done
    case "$(session_status "$SESSION")" in
        SUCCESS) return 0   ;;
        FAILED)  return 1   ;;
        KILLED)  return 125 ;;
        TIMEOUT) return 124 ;;
        *)       return 125 ;;
    esac
}

wait_for_session() {
    local SESSION="$1" TIMEOUT="${2:-300}" ELAPSED=0
    while session_running "$SESSION"; do
        sleep 1; ELAPSED=$((ELAPSED + 1))
        [ "$ELAPSED" -ge "$TIMEOUT" ] && {
            log_warn "Session still alive after ${TIMEOUT}s"
            return 124
        }
    done
    return 0
}

# ==============================================================================
# CLEANUP
# ==============================================================================

cleanup_session() {
    [ -n "$1" ] || return 1
    session_running "$1" && return 1
    rm -rf \
        "$(_ks_meta_dir "$1")" \
        "$(_ks_log_file "$1")" \
        "$KARSESSION_TMP_DIR/${1}.runner.sh" \
        2>/dev/null || true
}

cleanup_finished_sessions() {
    local S
    while IFS= read -r S; do
        [ -z "$S" ] && continue
        session_running "$S" || cleanup_session "$S"
    done < <(find "$KARSESSION_JOBS_DIR" \
                -mindepth 1 -maxdepth 1 -type d \
                -printf '%f\n' 2>/dev/null)
}

# ==============================================================================
# SESSION INFO
# ==============================================================================

session_info() {
    local SESSION="$1"
    [ -n "$SESSION" ] || return 1

    local LABEL STATUS EXIT CREATED STARTED FINISHED LOG
    LABEL=$(_ks_read_meta "$SESSION" "name"        2>/dev/null || printf '%s' "$SESSION")
    STATUS=$(session_status "$SESSION")
    EXIT=$(session_exit_code "$SESSION" 2>/dev/null || printf 'n/a')
    CREATED=$(_ks_read_meta "$SESSION" "created_at" 2>/dev/null || printf 'n/a')
    STARTED=$(_ks_read_meta "$SESSION" "started_at" 2>/dev/null || printf 'n/a')
    FINISHED=$(_ks_read_meta "$SESSION" "finished_at" 2>/dev/null || printf 'n/a')
    LOG="$(_ks_log_file "$SESSION")"

    printf '\n'
    printf "${_KS_BOLD}%s${_KS_RESET}\n" "══════════════════════════════════════════"
    printf "${_KS_BOLD} Session Info${_KS_RESET}\n"
    printf "${_KS_BOLD}%s${_KS_RESET}\n" "══════════════════════════════════════════"
    printf " %-12s %s\n" "Label:"    "$LABEL"
    printf " %-12s %s\n" "ID:"       "$SESSION"
    printf " %-12s "     "Status:"
    _ks_status_color "$STATUS"; printf '\n'
    printf " %-12s %s\n" "Exit:"     "$EXIT"
    printf " %-12s %s\n" "Created:"  "$CREATED"
    printf " %-12s %s\n" "Started:"  "$STARTED"
    printf " %-12s %s\n" "Finished:" "$FINISHED"
    printf " %-12s %s\n" "Log:"      "$LOG"
    printf "${_KS_BOLD}%s${_KS_RESET}\n\n" "══════════════════════════════════════════"
}

# ==============================================================================
# LEGACY COMPATIBILITY — check_session_success
# New code should use session_status() + session_exit_code() instead.
# ==============================================================================

check_session_success() {
    local SESSION="$1" TOOL="${2:-}"
    case "$(session_status "$SESSION")" in
        SUCCESS) return 0 ;;
        FAILED|KILLED|TIMEOUT) return 1 ;;
    esac
    local OUT; OUT=$(capture_session_output "$SESSION" 200 2>/dev/null || true)
    case "$TOOL" in
        msfconsole) echo "$OUT" | grep -qiE "session [0-9]+ opened" ;;
        hashcat)    echo "$OUT" | grep -qiE "status.*cracked|cracked" ;;
        john)       echo "$OUT" | grep -qiE "loaded.*password|cracked" ;;
        hydra)      echo "$OUT" | grep -qiE "login.*found|host.*found" ;;
        aircrack*)  echo "$OUT" | grep -qiE "key found" ;;
        *)          echo "$OUT" | grep -qiE "success|found|opened|cracked" ;;
    esac
}

# ==============================================================================
# INTERACTIVE SESSIONS MENU
# ==============================================================================

sessions_menu() {
    while true; do
        printf '\n'
        printf "${_KS_BOLD}══════════════════════════════════════════${_KS_RESET}\n"
        printf "${_KS_BOLD} KarSession — Active Jobs${_KS_RESET}\n"
        printf "${_KS_BOLD}══════════════════════════════════════════${_KS_RESET}\n"

        local -a SESSION_ARRAY=()
        while IFS= read -r s; do [[ -n "$s" ]] && SESSION_ARRAY+=("$s"); done \
            < <(list_sessions)

        local COUNT="${#SESSION_ARRAY[@]}"

        if [ "$COUNT" -eq 0 ]; then
            printf '\n'; log_warn "No active sessions."; printf '\n'
            read -r -p "  Press ENTER to go back..." _
            return 0
        fi

        printf '\n'
        printf "  ${_KS_DIM}%-3s  %-22s  %-10s  %s${_KS_RESET}\n" \
               "#" "Label" "Status" "Started"

        local i=1
        for s in "${SESSION_ARRAY[@]}"; do
            local LABEL STATUS STARTED
            LABEL=$(_ks_read_meta "$s" "name"       2>/dev/null || printf '%s' "$s")
            STATUS=$(session_status "$s")
            STARTED=$(_ks_read_meta "$s" "started_at" 2>/dev/null || printf 'n/a')
            printf '  %-3s  %-22s  ' "$i)" "$LABEL"
            _ks_status_color "$STATUS"
            printf '%-2s  %s\n' "" "$STARTED"
            i=$((i + 1))
        done

        printf '\n'
        printf '  a) Attach   i) Info   l) Log   k) Kill   c) Clean   r) Refresh   q) Quit\n'
        printf '\n'
        read -r -p "  > " OPT

        case "$OPT" in

            a|A)
                read -r -p "  Session # : " N
                local SN; SN="$(_ks_resolve "$N" 2>/dev/null)" || continue
                attach_session "$SN"
                ;;

            i|I)
                read -r -p "  Session # : " N
                local SN; SN="$(_ks_resolve "$N" 2>/dev/null)" || continue
                session_info "$SN"
                read -r -p "  Press ENTER to continue..." _
                ;;

            l|L)
                read -r -p "  Session # : " N
                local SN; SN="$(_ks_resolve "$N" 2>/dev/null)" || continue
                read -r -p "  Lines [50]: " LINES
                LINES="${LINES:-50}"
                printf '\n'
                capture_session_output "$SN" "$LINES"
                printf '\n'
                read -r -p "  Press ENTER to continue..." _
                ;;

            k|K)
                read -r -p "  Session # to kill: " N
                local SN; SN="$(_ks_resolve "$N" 2>/dev/null)" || continue
                end_session "$SN"
                log_success "Session killed."
                ;;

            c|C)
                cleanup_finished_sessions
                log_success "Finished session data cleaned."
                ;;

            r|R) continue ;;

            q|Q) return 0 ;;

            *) log_error "Invalid option." ;;

        esac
    done
}

# ==============================================================================
# CLI HELP
# ==============================================================================

_ks_help() {
cat <<HELP

${_KS_BOLD}╔══════════════════════════════════════════════════╗
║           KarSession v${KS_VERSION}                          ║
║     Persistent tmux session manager              ║
║     Author: Karim Refay                          ║
╚══════════════════════════════════════════════════╝${_KS_RESET}

${_KS_BOLD}WHAT IS IT?${_KS_RESET}
  Run any command in a persistent tracked tmux session.
  Close your terminal — it keeps running.
  Launch 10 tools at once — manage them all from one menu.
  Come back any time and check output, status, exit code.
  Click ctrl + b then d to out the session without kill it

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  MODE 1 — CLI  (one command, no scripting needed)${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ${_KS_CYAN}./karsession.sh run "COMMAND" [OPTIONS]${_KS_RESET}

  OPTIONS:
    --name  NAME    Label shown in the menu        (default: job)
    --wait          Block until command finishes
    --timeout N     Seconds before --wait gives up (default: 300)

  ${_KS_DIM}e.g. run a scan in the background and go do other things:${_KS_RESET}
    ./karsession.sh run "nmap -sV 192.168.1.1" --name nmap-scan

  ${_KS_DIM}e.g. start 3 tools at the same time:${_KS_RESET}
    ./karsession.sh run "nmap -sV 192.168.1.1"                   --name port-scan
    ./karsession.sh run "hashcat -m 1000 hash.txt rockyou.txt"   --name cracking
    ./karsession.sh run "gobuster dir -u http://target -w wl.txt" --name web-enum

  ${_KS_DIM}e.g. run and wait for result before continuing:${_KS_RESET}
    ./karsession.sh run "hydra -l admin -P pass.txt ssh://target" \
        --name hydra --wait --timeout 600

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  CLI COMMANDS${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ${_KS_CYAN}list${_KS_RESET}
    Show all sessions with label, status, and start time.
    ${_KS_DIM}e.g.  ./karsession.sh list${_KS_RESET}

  ${_KS_CYAN}menu${_KS_RESET}
    Open interactive dashboard — attach / info / log / kill / clean.
    ${_KS_DIM}e.g.  ./karsession.sh menu${_KS_RESET}

  ${_KS_CYAN}attach <# | session-id>${_KS_RESET}
    Enter a session live. Press Ctrl+B then D to detach without stopping it.
    ${_KS_DIM}e.g.  ./karsession.sh attach 1${_KS_RESET}
    ${_KS_DIM}e.g.  ./karsession.sh attach karsession_1728317234_4821${_KS_RESET}

  ${_KS_CYAN}info <# | session-id>${_KS_RESET}
    Print label, status, exit code, start/end times, log path.
    ${_KS_DIM}e.g.  ./karsession.sh info 2${_KS_RESET}

  ${_KS_CYAN}log <# | session-id> [--lines N]${_KS_RESET}
    Print last N lines of the session output log (default: 50).
    ${_KS_DIM}e.g.  ./karsession.sh log 1${_KS_RESET}
    ${_KS_DIM}e.g.  ./karsession.sh log 1 --lines 200${_KS_RESET}

  ${_KS_CYAN}status <# | session-id>${_KS_RESET}
    Print current status. Exits 0 if SUCCESS, 1 otherwise.
    ${_KS_DIM}e.g.  ./karsession.sh status 1${_KS_RESET}

  ${_KS_CYAN}kill <# | session-id>${_KS_RESET}
    Terminate a session immediately and mark it KILLED.
    ${_KS_DIM}e.g.  ./karsession.sh kill 3${_KS_RESET}

  ${_KS_CYAN}clean${_KS_RESET}
    Delete metadata and logs for all finished sessions.
    ${_KS_DIM}e.g.  ./karsession.sh clean${_KS_RESET}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  MODE 2 — LIBRARY  (source inside your own script)${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Add this one line at the top of your script:
    ${_KS_CYAN}source /path/to/karsession.sh${_KS_RESET}

  Then use run_in_session to launch any command — it gets its
  own tracked tmux session automatically.

  ${_KS_DIM}e.g. launch two jobs simultaneously and open the dashboard:${_KS_RESET}
    #!/usr/bin/env bash
    source /path/to/karsession.sh

    S1=\$(run_in_session "port-scan"  "nmap -sV 192.168.1.1")
    S2=\$(run_in_session "hash-crack" "hashcat -m 1000 hash.txt rockyou.txt")

    sessions_menu   # dashboard showing both jobs live

  ${_KS_DIM}e.g. wait for a job to finish before moving to next phase:${_KS_RESET}
    S1=\$(run_in_session "recon" "nmap -sV 192.168.1.1")
    wait_for_completion "\$S1" 300
    if [ \$? -eq 0 ]; then
        echo "Scan done — starting exploitation phase"
    fi

  ${_KS_DIM}e.g. check status and exit code from inside your script:${_KS_RESET}
    STATUS=\$(session_status "\$S1")     # RUNNING / SUCCESS / FAILED / ...
    EXIT=\$(session_exit_code "\$S1")    # 0, 1, 2 ...
    echo "Status: \$STATUS | Exit: \$EXIT"

  ${_KS_DIM}e.g. tail a running job's log live from another terminal:${_KS_RESET}
    tail -f /tmp/karsession/logs/<session-id>.log

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  LIBRARY API REFERENCE${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  run_in_session   NAME CMD        Start job; returns session ID
  list_sessions                    Print all active session IDs
  session_count                    Print integer count
  session_status   ID              CREATED/RUNNING/SUCCESS/FAILED/KILLED/TIMEOUT
  session_exit_code ID             Exit code once job finishes
  session_info     ID              Print full metadata table
  attach_session   ID              tmux attach (Ctrl+B D to detach)
  end_session      ID              Kill + mark KILLED
  capture_session_output ID [N]    Last N lines of live or logged output
  is_session_done  ID              Returns 0 if command has finished
  wait_for_completion ID [TIMEOUT] Block until done — returns 0/1/124/125
  sessions_menu                    Open interactive TUI dashboard
  cleanup_session  ID              Remove metadata for one finished job
  cleanup_finished_sessions        Remove all finished jobs' metadata

  wait_for_completion return codes:
    0   → SUCCESS  (command exited 0)
    1   → FAILED   (command exited non-zero)
    124 → TIMEOUT  (exceeded the timeout you set)
    125 → UNKNOWN  (killed or state unclear)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  SESSION STATES${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  CREATED  → registered, not yet started
  RUNNING  → tmux session alive, command executing
  SUCCESS  → command exited 0
  FAILED   → command exited non-zero
  TIMEOUT  → wait_for_completion ran out of time
  KILLED   → end_session was called manually

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  SESSION LOGS${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Every job writes a full log automatically:
    \$KARSESSION_STATE_DIR/logs/<session-id>.log

  ${_KS_DIM}e.g. tail live:${_KS_RESET}
    tail -f /tmp/karsession/logs/karsession_1728317234_4821.log

  ${_KS_DIM}e.g. view via CLI:${_KS_RESET}
    ./karsession.sh log 1 --lines 100

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  ENVIRONMENT VARIABLES${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  SESSION_PREFIX        tmux name prefix        (default: karsession)
  KARSESSION_STATE_DIR  metadata + logs root    (default: /tmp/karsession)

  ${_KS_DIM}e.g. keep logs after reboot:${_KS_RESET}
    export KARSESSION_STATE_DIR="\$HOME/.karsession"
    source karsession.sh

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${_KS_BOLD}  REQUIREMENT${_KS_RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  sudo apt install tmux

HELP
}

# ==============================================================================
# CLI DISPATCHER
# ==============================================================================

_ks_main() {
    [ $# -eq 0 ] && { _ks_help; exit 0; }

    case "$1" in

        run)
            shift
            local CMD="" NAME="job" WAIT=0 TIMEOUT=300
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)    NAME="$2"; shift 2 ;;
                    --wait)    WAIT=1; shift ;;
                    --timeout) TIMEOUT="$2"; shift 2 ;;
                    -*)        log_error "Unknown flag: $1"; exit 1 ;;
                    *)
                        if [ -z "$CMD" ]; then CMD="$1"; shift
                        else log_error "Unexpected argument: $1"; exit 1
                        fi
                        ;;
                esac
            done
            [ -n "$CMD" ] || { log_error "No command given. Usage: karsession.sh run \"cmd\" [--name NAME]"; exit 1; }

            local SESSION
            SESSION=$(run_in_session "$NAME" "$CMD") || exit 1
            printf '\n'
            log_info "Session ID: ${_KS_BOLD}$SESSION${_KS_RESET}"
            log_info "Attach:     karsession.sh attach $SESSION"
            log_info "Menu:       karsession.sh menu"
            printf '\n'

            if [ "$WAIT" -eq 1 ]; then
                log_info "Waiting (timeout: ${TIMEOUT}s)…"
                wait_for_completion "$SESSION" "$TIMEOUT"
                local RC=$?
                session_info "$SESSION"
                exit $RC
            fi
            ;;

        list)
            local -a ALL=()
            while IFS= read -r s; do [[ -n "$s" ]] && ALL+=("$s"); done \
                < <(list_sessions)
            local COUNT="${#ALL[@]}"
            if [ "$COUNT" -eq 0 ]; then
                log_warn "No active KarSession sessions."; exit 0
            fi
            printf '\n'
            printf "${_KS_BOLD}  %-3s  %-22s  %-10s  %s${_KS_RESET}\n" \
                   "#" "Label" "Status" "Started"
            local i=1
            for s in "${ALL[@]}"; do
                local LABEL STARTED STATUS
                LABEL=$(_ks_read_meta "$s" "name"       2>/dev/null || printf '%s' "$s")
                STATUS=$(session_status "$s")
                STARTED=$(_ks_read_meta "$s" "started_at" 2>/dev/null || printf 'n/a')
                printf '  %-3s  %-22s  ' "$i)" "$LABEL"
                _ks_status_color "$STATUS"
                printf '%-4s  %s\n' "" "$STARTED"
                i=$((i + 1))
            done
            printf '\n'
            ;;

        attach)
            [ -n "${2:-}" ] || { log_error "Usage: karsession.sh attach <#|ID>"; exit 1; }
            local SN; SN="$(_ks_resolve "$2")" || exit 1
            attach_session "$SN"
            ;;

        info)
            [ -n "${2:-}" ] || { log_error "Usage: karsession.sh info <#|ID>"; exit 1; }
            local SN; SN="$(_ks_resolve "$2")" || exit 1
            session_info "$SN"
            ;;

        log)
            [ -n "${2:-}" ] || { log_error "Usage: karsession.sh log <#|ID> [--lines N]"; exit 1; }
            local SN; SN="$(_ks_resolve "$2")" || exit 1
            local LINES=50
            [ "${3:-}" = "--lines" ] && LINES="${4:-50}"
            printf '\n'
            capture_session_output "$SN" "$LINES"
            printf '\n'
            ;;

        status)
            [ -n "${2:-}" ] || { log_error "Usage: karsession.sh status <#|ID>"; exit 1; }
            local SN; SN="$(_ks_resolve "$2")" || exit 1
            local S; S=$(session_status "$SN")
            _ks_status_color "$S"; printf '\n'
            [[ "$S" == "SUCCESS" ]] && exit 0 || exit 1
            ;;

        kill)
            [ -n "${2:-}" ] || { log_error "Usage: karsession.sh kill <#|ID>"; exit 1; }
            local SN; SN="$(_ks_resolve "$2")" || exit 1
            end_session "$SN" && log_success "Killed: $SN"
            ;;

        clean)
            cleanup_finished_sessions
            log_success "Finished session data cleaned."
            ;;

        menu)
            sessions_menu
            ;;

        -h|--help)
            _ks_help
            ;;

        --version)
            printf 'KarSession %s\n' "$KS_VERSION"
            ;;

        *)
            log_error "Unknown command: $1"
            printf 'Run: karsession.sh --help\n'
            exit 1
            ;;
    esac
}

# ==============================================================================
# ENTRY POINT
# Detect whether this file is being sourced (library mode) or executed (CLI).
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _ks_main "$@"
fi
