#!/bin/bash
#
# Simple monitoring dashboard for RTSP ROI Counter
# Shows real-time status without needing a GUI
#

PI_IP="${1:-localhost}"
STATUS_PORT="${2:-8080}"
REFRESH_INTERVAL=5

if [ "$PI_IP" = "-h" ] || [ "$PI_IP" = "--help" ]; then
    echo "Usage: $0 [pi_ip] [port]"
    echo ""
    echo "Examples:"
    echo "  $0                    # Monitor localhost"
    echo "  $0 192.168.1.100      # Monitor remote Pi"
    echo "  $0 192.168.1.100 8080 # Monitor remote Pi on port 8080"
    exit 0
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Installing jq for JSON parsing..."
    sudo apt-get install -y jq
fi

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Install it with: sudo apt-get install curl"
    exit 1
fi

STATUS_URL="http://${PI_IP}:${STATUS_PORT}/status"

echo "=== RTSP ROI Counter Monitor ==="
echo "Target: $STATUS_URL"
echo "Press Ctrl+C to exit"
echo ""

while true; do
    clear
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  RTSP ROI Counter - Live Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Fetch status
    STATUS=$(curl -s --connect-timeout 5 "$STATUS_URL" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$STATUS" ]; then
        # Parse JSON
        SERVICE_STATUS=$(echo "$STATUS" | jq -r '.status // "unknown"')
        UPTIME=$(echo "$STATUS" | jq -r '.uptime // 0')
        FPS=$(echo "$STATUS" | jq -r '.performance.fps // 0')
        AVG_TIME=$(echo "$STATUS" | jq -r '.performance.avg_processing_time_ms // 0')
        TOTAL_FRAMES=$(echo "$STATUS" | jq -r '.performance.total_frames // 0')
        PERSON_COUNT=$(echo "$STATUS" | jq -r '.performance.recent_person_count // 0')
        VEHICLE_COUNT=$(echo "$STATUS" | jq -r '.performance.recent_vehicle_count // 0')
        RTSP_URL=$(echo "$STATUS" | jq -r '.config.rtsp_url // "N/A"')
        ROI_NAME=$(echo "$STATUS" | jq -r '.config.roi.name // "default"')
        TIMESTAMP=$(echo "$STATUS" | jq -r '.timestamp // "N/A"')
        
        # Format uptime
        UPTIME_HOURS=$(echo "scale=1; $UPTIME / 3600" | bc)
        
        # Status indicator
        if [ "$SERVICE_STATUS" = "running" ]; then
            STATUS_ICON="✓"
            STATUS_COLOR="\033[0;32m"  # Green
        else
            STATUS_ICON="✗"
            STATUS_COLOR="\033[0;31m"  # Red
        fi
        
        echo -e "  Status: ${STATUS_COLOR}${STATUS_ICON} ${SERVICE_STATUS}${NC}"
        echo "  Uptime: ${UPTIME_HOURS}h"
        echo "  Last update: $TIMESTAMP"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Performance Metrics"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        printf "  %-25s %s\n" "FPS:" "$FPS fps"
        printf "  %-25s %s\n" "Avg Processing Time:" "${AVG_TIME} ms"
        printf "  %-25s %s\n" "Total Frames:" "$TOTAL_FRAMES"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Detection Counts (Recent Average)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        printf "  %-25s %.1f\n" "Persons in ROI:" "$PERSON_COUNT"
        printf "  %-25s %.1f\n" "Vehicles in ROI:" "$VEHICLE_COUNT"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Configuration"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        printf "  %-25s %s\n" "RTSP URL:" "$RTSP_URL"
        printf "  %-25s %s\n" "ROI Name:" "$ROI_NAME"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  System Info"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Get memory info if on same machine
        if [ "$PI_IP" = "localhost" ] || [ "$PI_IP" = "127.0.0.1" ]; then
            MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
            MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')
            MEM_PERCENT=$(free | awk '/^Mem:/ {printf("%.1f", $3/$2 * 100.0)}')
            
            printf "  %-25s %s MB / %s MB (%.1f%%)\n" "Memory:" "$MEM_USED" "$MEM_TOTAL" "$MEM_PERCENT"
            
            # Get CPU temp if available
            if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
                CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
                CPU_TEMP_C=$(echo "scale=1; $CPU_TEMP / 1000" | bc)
                printf "  %-25s %s°C\n" "CPU Temperature:" "$CPU_TEMP_C"
            fi
        fi
        
    else
        echo -e "\033[0;31m✗ Cannot connect to service\033[0m"
        echo ""
        echo "  URL: $STATUS_URL"
        echo "  Possible reasons:"
        echo "  - Service is not running"
        echo "  - Wrong IP address or port"
        echo "  - Firewall blocking connection"
        echo ""
        echo "  Try:"
        echo "  - Check service: sudo systemctl status rtsp-roi-counter"
        echo "  - Check logs: sudo journalctl -u rtsp-roi-counter -n 50"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Press Ctrl+C to exit | Refreshing in ${REFRESH_INTERVAL}s..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    sleep $REFRESH_INTERVAL
done
