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

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

log "Starting glances-alert.sh script"

# Run Glances and get output using the correct format
# Using timeout to ensure glances only runs for 2 seconds
RAW_OUTPUT=$(timeout 2 glances --stdout cpu,mem,fs)
log "Raw glances output:"
log "$RAW_OUTPUT"

# Extract values using sed for more precise parsing and clean up the output
CPU_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/'total':/s/.*'total': \([0-9.]*\).*/\1/p" | head -n1)
MEM_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/mem:/,/}/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)
DISK_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/fs:/,/}/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)

log "Parsed values:"
log "CPU_USAGE=$CPU_USAGE"
log "MEM_USAGE=$MEM_USAGE"
log "DISK_USAGE=$DISK_USAGE"

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