#!/bin/bash

# CONFIGURATION
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
CPU_THRESHOLD=80
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

# Run Glances and get output
RAW_OUTPUT=$(glances --stdout-json cpu,mem,fs --stop-after 1)
log "Raw glances output:"
log "$RAW_OUTPUT"

# Extract JSON chunks
CPU_JSON=$(echo "$RAW_OUTPUT" | grep '^cpu:' | cut -d':' -f2-)
MEM_JSON=$(echo "$RAW_OUTPUT" | grep '^mem:' | cut -d':' -f2-)
FS_JSON=$(echo "$RAW_OUTPUT" | grep '^fs:'  | cut -d':' -f2-)

# Validate that we have data
if [ -z "$CPU_JSON" ] || [ -z "$MEM_JSON" ] || [ -z "$FS_JSON" ]; then
    log "ERROR: One or more JSON blocks are empty"
    exit 1
fi

# Parse values
CPU_USAGE=$(echo "$CPU_JSON" | jq '.total')
MEM_USAGE=$(echo "$MEM_JSON" | jq '.percent')
DISK_USAGE=$(echo "$FS_JSON" | jq '[.[].percent] | max')

log "Parsed values:"
log "CPU_USAGE=$CPU_USAGE"
log "MEM_USAGE=$MEM_USAGE"
log "DISK_USAGE=$DISK_USAGE"

# Check values are numeric
if ! [[ "$CPU_USAGE" =~ ^[0-9.]+$ && "$MEM_USAGE" =~ ^[0-9.]+$ && "$DISK_USAGE" =~ ^[0-9.]+$ ]]; then
    log "ERROR: One of the values is not numeric"
    exit 1
fi

# Build alert message
ALERT_MSG=""
if (( $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) )); then
    ALERT_MSG+="⚠️ *High CPU usage*: ${CPU_USAGE}%\n"
    log "CPU usage exceeded threshold"
fi
if (( $(echo "$MEM_USAGE > $MEM_THRESHOLD" | bc -l) )); then
    ALERT_MSG+="⚠️ *High Memory usage*: ${MEM_USAGE}%\n"
    log "Memory usage exceeded threshold"
fi
if (( $(echo "$DISK_USAGE > $DISK_THRESHOLD" | bc -l) )); then
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

