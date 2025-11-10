#!/bin/bash
#
# Memory Monitor Wrapper for RTSP ROI Counter
# Monitors process memory usage and terminates if threshold exceeded
# Usage: memory_monitor_wrapper.sh <config.json> <memory_threshold_mb>
#

set -e

CONFIG_FILE="${1}"
MEMORY_THRESHOLD_MB="${2:-1500}"  # Default 1.5GB for Pi5 with 2GB RAM
CHECK_INTERVAL=30  # Check every 30 seconds

if [ -z "$CONFIG_FILE" ]; then
    echo "Usage: $0 <config.json> [memory_threshold_mb]"
    echo "Example: $0 /etc/rtsp_roi_counter/config.json 1500"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log file
LOG_FILE="/var/log/memory_monitor.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

get_process_memory_mb() {
    local pid=$1
    # Get RSS (Resident Set Size) in KB and convert to MB
    local mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
    echo $((mem_kb / 1024))
}

get_total_memory_mb() {
    # Get total used memory in MB
    free -m | awk '/^Mem:/ {print $3}'
}

get_memory_percent() {
    # Get memory usage percentage
    free | awk '/^Mem:/ {printf("%.1f", $3/$2 * 100.0)}'
}

# Start the main process
log_message "Starting RTSP ROI Counter with memory monitoring"
log_message "Config: $CONFIG_FILE"
log_message "Memory threshold: ${MEMORY_THRESHOLD_MB}MB"

# Start Python script in background
python3 "$SCRIPT_DIR/rtsp_roi_counter.py" "$CONFIG_FILE" &
MAIN_PID=$!

log_message "Main process started with PID: $MAIN_PID"

# Trap signals to ensure cleanup
cleanup() {
    log_message "Cleaning up... Terminating PID $MAIN_PID"
    kill -TERM "$MAIN_PID" 2>/dev/null || true
    wait "$MAIN_PID" 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Monitor loop
while kill -0 "$MAIN_PID" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"
    
    # Check if process still exists
    if ! kill -0 "$MAIN_PID" 2>/dev/null; then
        log_message "Main process terminated"
        break
    fi
    
    # Get memory usage
    PROCESS_MEM_MB=$(get_process_memory_mb "$MAIN_PID")
    TOTAL_MEM_MB=$(get_total_memory_mb)
    MEM_PERCENT=$(get_memory_percent)
    
    log_message "Memory check: Process=${PROCESS_MEM_MB}MB, Total=${TOTAL_MEM_MB}MB (${MEM_PERCENT}%)"
    
    # Check process memory
    if [ "$PROCESS_MEM_MB" -gt "$MEMORY_THRESHOLD_MB" ]; then
        log_message "WARNING: Process memory ($PROCESS_MEM_MB MB) exceeds threshold ($MEMORY_THRESHOLD_MB MB)"
        log_message "Terminating process to prevent OOM"
        kill -TERM "$MAIN_PID"
        sleep 5
        kill -KILL "$MAIN_PID" 2>/dev/null || true
        exit 1
    fi
    
    # Also check system memory (95% threshold)
    if (( $(echo "$MEM_PERCENT > 95" | bc -l) )); then
        log_message "WARNING: System memory usage ($MEM_PERCENT%) critically high"
        log_message "Terminating process to prevent system instability"
        kill -TERM "$MAIN_PID"
        sleep 5
        kill -KILL "$MAIN_PID" 2>/dev/null || true
        exit 1
    fi
done

# Wait for main process
wait "$MAIN_PID"
EXIT_CODE=$?

log_message "Process exited with code: $EXIT_CODE"
exit $EXIT_CODE
