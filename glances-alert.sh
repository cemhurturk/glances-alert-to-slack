#!/bin/bash

# CONFIGURATION
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
HOSTNAME=$(hostname)

# CPU measurement window in seconds (increase for more stable readings)
CPU_MEASURE_SECONDS=5

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

log "Starting glances-alert.sh script"

# Run Glances for longer period to get averaged CPU usage
# The last reading from glances will be the average over the time period
RAW_OUTPUT=$(timeout $CPU_MEASURE_SECONDS glances --stdout cpu.total,mem,fs --time 1 2>/dev/null | tail -n 3)

# If timeout doesn't give us output, fall back to single reading
if [ -z "$RAW_OUTPUT" ]; then
    log "Falling back to single glances reading"
    RAW_OUTPUT=$(timeout 2 glances --stdout cpu.total,mem,fs)
fi

log "Raw glances output:"
log "$RAW_OUTPUT"

# Extract CPU usage - looking specifically for the cpu.total line
CPU_USAGE=$(echo "$RAW_OUTPUT" | grep "cpu.total:" | tail -1 | awk '{print $2}')

# If that doesn't work, try alternative parsing
if [ -z "$CPU_USAGE" ] || ! [[ "$CPU_USAGE" =~ ^[0-9.]+$ ]]; then
    # Look for the pattern "cpu.total: <number>"
    CPU_USAGE=$(echo "$RAW_OUTPUT" | sed -n 's/^cpu\.total: \([0-9.]*\)/\1/p' | tail -1)
fi

# Extract memory usage - look for percent within mem section
MEM_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/^mem:/,/^[a-z]/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)

# Extract disk usage - look for percent within fs section
DISK_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/^fs:/,/^[a-z]/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)

log "Parsed values:"
log "CPU_USAGE=$CPU_USAGE% (${CPU_MEASURE_SECONDS}-second measurement)"
log "MEM_USAGE=$MEM_USAGE%"
log "DISK_USAGE=$DISK_USAGE%"

# Check values are numeric
if ! [[ "$CPU_USAGE" =~ ^[0-9.]+$ && "$MEM_USAGE" =~ ^[0-9.]+$ && "$DISK_USAGE" =~ ^[0-9.]+$ ]]; then
    log "ERROR: One of the values is not numeric"
    log "DEBUG: CPU_USAGE=$CPU_USAGE"
    log "DEBUG: MEM_USAGE=$MEM_USAGE"
    log "DEBUG: DISK_USAGE=$DISK_USAGE"
    exit 1
fi

# Build alert message
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

# Handle Slack alert with throttling
if [ -n "$ALERT_MSG" ]; then
    CURRENT_TIME=$(date +%s)
    LAST_ALERT_TIME=0

    if [ -f "$STATE_FILE" ]; then
        LAST_ALERT_TIME=$(cat "$STATE_FILE")
    fi

    TIME_DIFF=$(( (CURRENT_TIME - LAST_ALERT_TIME) / 60 ))
    log "Time since last alert: $TIME_DIFF minutes"

    if [ "$TIME_DIFF" -ge "$ALERT_COOLDOWN_MINUTES" ]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"*🚨 Alert from $HOSTNAME:*\n$ALERT_MSG\"}" \
            "$SLACK_WEBHOOK_URL" \
            && log "Slack alert sent." \
            || log "ERROR: Failed to send Slack alert."

        echo "$CURRENT_TIME" > "$STATE_FILE"
    else
        log "Alert throttled. Not enough time has passed."
    fi
else
    log "No thresholds exceeded. No alert sent."
fi

# Optional: Add a status line to the log showing current metrics
log "STATUS: CPU=${CPU_USAGE}%, MEM=${MEM_USAGE}%, DISK=${DISK_USAGE}%"
