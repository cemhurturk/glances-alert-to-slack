#!/bin/bash
#
# glances-alert.sh
#
# Lightweight system monitor that reads CPU / memory / disk usage from
# `glances --stdout` and posts a Slack alert when thresholds are exceeded.
#

set -u

# ---------- CONFIGURATION ------------------------------------------------

CHECK_CPU=1
CHECK_MEM=1
CHECK_DISK=1

SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"

CPU_THRESHOLD=90
MEM_THRESHOLD=80
DISK_THRESHOLD=80

ALERT_COOLDOWN_MINUTES=10

STATE_FILE="/tmp/glances-alert.last"
LOG_FILE="/tmp/glances-alert.log"
LOCK_FILE="/tmp/glances-alert.lock"

HOSTNAME=$(hostname)

CPU_MEASURE_SECONDS=5
GLANCES_KILL_AFTER_SECONDS=3

# ---------- HELPERS ------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

TMP_OUT="$(mktemp -t glances-alert.XXXXXX)"

cleanup() {
    local children
    children=$(pgrep -P $$ 2>/dev/null || true)
    if [ -n "$children" ]; then
        # shellcheck disable=SC2086
        kill $children 2>/dev/null || true
        sleep 1
        # shellcheck disable=SC2086
        kill -9 $children 2>/dev/null || true
    fi
    rm -f "$TMP_OUT"
}
trap cleanup EXIT INT TERM

# ---------- PREVENT OVERLAPPING RUNS ------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another glances-alert run is already in progress. Skipping."
    exit 0
fi

log "Starting glances-alert.sh script"

# ---------- SAMPLE GLANCES ----------------------------------------------

timeout --kill-after="${GLANCES_KILL_AFTER_SECONDS}s" "${CPU_MEASURE_SECONDS}s" \
    glances --stdout cpu.total,mem,fs --time 1 --stop-after "${CPU_MEASURE_SECONDS}" \
    > "$TMP_OUT" 2>/dev/null
GLANCES_RC=$?

if [ ! -s "$TMP_OUT" ]; then
    log "Primary glances reading produced no output (rc=$GLANCES_RC), trying fallback"
    timeout --kill-after="${GLANCES_KILL_AFTER_SECONDS}s" 2s \
        glances --stdout cpu.total,mem,fs --stop-after 2 \
        > "$TMP_OUT" 2>/dev/null
fi

if [ ! -s "$TMP_OUT" ]; then
    log "ERROR: glances produced no output in either attempt. Aborting."
    exit 1
fi

RAW_OUTPUT=$(tail -n 20 "$TMP_OUT")

log "Raw glances output:"
log "$RAW_OUTPUT"

# ---------- PARSE --------------------------------------------------------

CPU_USAGE=$(echo "$RAW_OUTPUT" | grep "cpu.total:" | tail -1 | awk '{print $2}')
if [ -z "$CPU_USAGE" ] || ! [[ "$CPU_USAGE" =~ ^[0-9.]+$ ]]; then
    CPU_USAGE=$(echo "$RAW_OUTPUT" | sed -n 's/^cpu\.total: \([0-9.]*\)/\1/p' | tail -1)
fi

MEM_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/^mem:/,/^[a-z]/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)
DISK_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/^fs:/,/^[a-z]/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)

log "Parsed values:"
log "CPU_USAGE=$CPU_USAGE% (${CPU_MEASURE_SECONDS}-second measurement)"
log "MEM_USAGE=$MEM_USAGE%"
log "DISK_USAGE=$DISK_USAGE%"

if ! [[ "$CPU_USAGE" =~ ^[0-9.]+$ && "$MEM_USAGE" =~ ^[0-9.]+$ && "$DISK_USAGE" =~ ^[0-9.]+$ ]]; then
    log "ERROR: One of the values is not numeric"
    log "DEBUG: CPU_USAGE=$CPU_USAGE"
    log "DEBUG: MEM_USAGE=$MEM_USAGE"
    log "DEBUG: DISK_USAGE=$DISK_USAGE"
    exit 1
fi

# ---------- BUILD ALERT --------------------------------------------------

ALERT_MSG=""
if [ "$CHECK_CPU" -eq 1 ] && (( $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) )); then
    ALERT_MSG+="⚠️ *High CPU usage*: ${CPU_USAGE}%\n"
    log "CPU usage exceeded threshold"
fi
if [ "$CHECK_MEM" -eq 1 ] && (( $(echo "$MEM_USAGE > $MEM_THRESHOLD" | bc -l) )); then
    ALERT_MSG+="⚠️ *High Memory usage*: ${MEM_USAGE}%\n"
    log "Memory usage exceeded threshold"
fi
if [ "$CHECK_DISK" -eq 1 ] && (( $(echo "$DISK_USAGE > $DISK_THRESHOLD" | bc -l) )); then
    ALERT_MSG+="⚠️ *High Disk usage*: ${DISK_USAGE}%\n"
    log "Disk usage exceeded threshold"
fi

# ---------- SEND SLACK (with cooldown) ----------------------------------

if [ -n "$ALERT_MSG" ]; then
    CURRENT_TIME=$(date +%s)
    LAST_ALERT_TIME=0

    if [ -f "$STATE_FILE" ]; then
        LAST_ALERT_TIME=$(cat "$STATE_FILE")
    fi

    TIME_DIFF=$(( (CURRENT_TIME - LAST_ALERT_TIME) / 60 ))
    log "Time since last alert: $TIME_DIFF minutes"

    if [ "$TIME_DIFF" -ge "$ALERT_COOLDOWN_MINUTES" ]; then
        if curl -s --max-time 10 -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"*🚨 Alert from $HOSTNAME:*\n$ALERT_MSG\"}" \
            "$SLACK_WEBHOOK_URL"; then
            log "Slack alert sent."
        else
            log "ERROR: Failed to send Slack alert."
        fi

        echo "$CURRENT_TIME" > "$STATE_FILE"
    else
        log "Alert throttled. Not enough time has passed."
    fi
else
    log "No thresholds exceeded. No alert sent."
fi

log "STATUS: CPU=${CPU_USAGE}%, MEM=${MEM_USAGE}%, DISK=${DISK_USAGE}%"
