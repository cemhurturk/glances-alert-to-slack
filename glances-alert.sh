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

# Method 1: Using glances with percpu to get steal time
# This gets per-CPU stats including steal time
RAW_OUTPUT=$(timeout 2 glances --stdout cpu.total,percpu,mem,fs)
log "Raw glances output:"
log "$RAW_OUTPUT"

# Extract total CPU usage and steal time
TOTAL_CPU=$(echo "$RAW_OUTPUT" | sed -n "/'total':/s/.*'total': \([0-9.]*\).*/\1/p" | head -n1)
STEAL_TIME=$(echo "$RAW_OUTPUT" | sed -n "/'steal':/s/.*'steal': \([0-9.]*\).*/\1/p" | head -n1)

# If glances doesn't provide steal time, try using /proc/stat directly
if [ -z "$STEAL_TIME" ] || ! [[ "$STEAL_TIME" =~ ^[0-9.]+$ ]]; then
    log "Steal time not found in glances output, using /proc/stat"
    
    # Read CPU stats from /proc/stat
    CPU_STATS=$(cat /proc/stat | grep "^cpu " | head -n1)
    
    # Parse the values (user nice system idle iowait irq softirq steal guest guest_nice)
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice <<< "$CPU_STATS"
    
    # Calculate percentages
    if [ -n "$steal" ]; then
        total=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
        if [ "$total" -gt 0 ]; then
            # Sleep briefly to get a second reading for percentage calculation
            sleep 1
            CPU_STATS2=$(cat /proc/stat | grep "^cpu " | head -n1)
            read -r cpu2 user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 <<< "$CPU_STATS2"
            
            total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2 + guest2 + guest_nice2))
            
            # Calculate differences
            total_diff=$((total2 - total))
            steal_diff=$((steal2 - steal))
            idle_diff=$((idle2 - idle))
            
            if [ "$total_diff" -gt 0 ]; then
                STEAL_TIME=$(echo "scale=2; ($steal_diff * 100) / $total_diff" | bc -l)
                ACTUAL_USAGE=$(echo "scale=2; ((($total_diff - $idle_diff) * 100) / $total_diff) - $STEAL_TIME" | bc -l)
                log "Calculated from /proc/stat: STEAL_TIME=$STEAL_TIME, ACTUAL_USAGE=$ACTUAL_USAGE"
            fi
        fi
    fi
fi

# Calculate actual CPU usage excluding steal time
if [ -n "$STEAL_TIME" ] && [[ "$STEAL_TIME" =~ ^[0-9.]+$ ]]; then
    CPU_USAGE=$(echo "scale=2; $TOTAL_CPU - $STEAL_TIME" | bc -l)
    log "Total CPU: $TOTAL_CPU%, Steal Time: $STEAL_TIME%, Actual CPU: $CPU_USAGE%"
else
    # Fallback to total CPU if we can't determine steal time
    CPU_USAGE=$TOTAL_CPU
    STEAL_TIME="0"
    log "Could not determine steal time, using total CPU: $CPU_USAGE%"
fi

# Extract memory and disk usage as before
MEM_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/mem:/,/}/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)
DISK_USAGE=$(echo "$RAW_OUTPUT" | sed -n "/fs:/,/}/s/.*'percent': \([0-9.]*\).*/\1/p" | head -n1)

log "Parsed values:"
log "CPU_USAGE=$CPU_USAGE (excluding steal time: $STEAL_TIME%)"
log "MEM_USAGE=$MEM_USAGE"
log "DISK_USAGE=$DISK_USAGE"

# Check values are numeric
if ! [[ "$CPU_USAGE" =~ ^[0-9.-]+$ && "$MEM_USAGE" =~ ^[0-9.]+$ && "$DISK_USAGE" =~ ^[0-9.]+$ ]]; then
    log "ERROR: One of the values is not numeric"
    log "DEBUG: CPU_USAGE=$CPU_USAGE"
    log "DEBUG: MEM_USAGE=$MEM_USAGE"
    log "DEBUG: DISK_USAGE=$DISK_USAGE"
    exit 1
fi

# Build alert message
ALERT_MSG=""
if [ "$CHECK_CPU" -eq 1 ] && (( $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) )); then
    ALERT_MSG+="⚠️ *High CPU usage*: ${CPU_USAGE}% (actual, excluding ${STEAL_TIME}% steal time)\n"
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
log "STATUS: CPU=${CPU_USAGE}% (steal=${STEAL_TIME}%), MEM=${MEM_USAGE}%, DISK=${DISK_USAGE}%"
