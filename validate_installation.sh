#!/bin/bash
#
# RTSP ROI Counter - Installation Validation Script
# Checks all prerequisites and configuration before deployment
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

print_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

# Start validation
print_header "RTSP ROI Counter - Installation Validator"

# 1. Check Python installation
print_header "1. Python Environment"

if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | awk '{print $2}')
    check_pass "Python 3 installed: $PYTHON_VERSION"
else
    check_fail "Python 3 not found"
fi

# Check Python modules
for module in gi json logging threading; do
    if python3 -c "import $module" 2>/dev/null; then
        check_pass "Python module '$module' available"
    else
        check_fail "Python module '$module' missing"
    fi
done

# 2. Check GStreamer
print_header "2. GStreamer Installation"

if command -v gst-launch-1.0 &> /dev/null; then
    GST_VERSION=$(gst-launch-1.0 --version | grep version | awk '{print $2}')
    check_pass "GStreamer installed: $GST_VERSION"
else
    check_fail "GStreamer not found"
fi

# Check GStreamer plugins
REQUIRED_PLUGINS="hailonet hailofilter rtspsrc rtph264depay h264parse avdec_h264 videoconvert videoscale"
for plugin in $REQUIRED_PLUGINS; do
    if gst-inspect-1.0 $plugin &> /dev/null; then
        check_pass "GStreamer plugin '$plugin' available"
    else
        check_fail "GStreamer plugin '$plugin' missing"
    fi
done

# 3. Check Hailo installation
print_header "3. Hailo Environment"

HAILO_APPS_PATH="/home/pi/hailo_apps_infra"
if [ -d "$HAILO_APPS_PATH" ]; then
    check_pass "hailo_apps_infra directory exists"
else
    check_fail "hailo_apps_infra directory not found at $HAILO_APPS_PATH"
fi

SETUP_ENV="${HAILO_APPS_PATH}/setup_env.sh"
if [ -f "$SETUP_ENV" ]; then
    check_pass "setup_env.sh found"
else
    check_fail "setup_env.sh not found at $SETUP_ENV"
fi

# Check Hailo model
MODEL_PATH="${HAILO_APPS_PATH}/resources/models/hailo8/yolov6n.hef"
if [ -f "$MODEL_PATH" ]; then
    check_pass "YOLOv6n model found"
else
    check_warn "Default model not found at $MODEL_PATH (may use custom path)"
fi

# Check postprocess library
POSTPROCESS_PATHS=(
    "${HAILO_APPS_PATH}/resources/so/libyolo_hailortpp_postprocess.so"
    "/usr/local/hailo/resources/so/libyolo_hailortpp_postprocess.so"
    "/usr/lib/aarch64-linux-gnu/hailo/tappas/post_processes/libyolo_hailortpp_postprocess.so"
)

FOUND_POSTPROCESS=false
for path in "${POSTPROCESS_PATHS[@]}"; do
    if [ -f "$path" ]; then
        check_pass "Postprocess library found: $path"
        FOUND_POSTPROCESS=true
        break
    fi
done

if [ "$FOUND_POSTPROCESS" = false ]; then
    check_fail "Postprocess library not found in any standard location"
fi

# 4. Check application files
print_header "4. Application Files"

APP_DIR="/home/pi/rtsp_roi_counter"
if [ -d "$APP_DIR" ]; then
    check_pass "Application directory exists"
else
    check_fail "Application directory not found at $APP_DIR"
fi

REQUIRED_FILES=(
    "${APP_DIR}/rtsp_roi_counter.py"
    "${APP_DIR}/memory_monitor_wrapper.sh"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        if [ -x "$file" ]; then
            check_pass "$(basename $file) exists and is executable"
        else
            check_warn "$(basename $file) exists but is not executable"
            echo "  Fix with: chmod +x $file"
        fi
    else
        check_fail "$(basename $file) not found"
    fi
done

# 5. Check configuration
print_header "5. Configuration"

CONFIG_DIR="/etc/rtsp_roi_counter"
CONFIG_FILE="${CONFIG_DIR}/config.json"

if [ -d "$CONFIG_DIR" ]; then
    check_pass "Config directory exists"
else
    check_warn "Config directory not found at $CONFIG_DIR"
fi

if [ -f "$CONFIG_FILE" ]; then
    check_pass "Configuration file exists"
    
    # Validate JSON
    if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
        check_pass "Configuration is valid JSON"
        
        # Check required fields
        REQUIRED_FIELDS="rtsp_url roi hef_path postprocess_so"
        for field in $REQUIRED_FIELDS; do
            if python3 -c "import json; config=json.load(open('$CONFIG_FILE')); exit(0 if '$field' in config else 1)" 2>/dev/null; then
                check_pass "Config has required field: $field"
            else
                check_fail "Config missing required field: $field"
            fi
        done
        
        # Test RTSP URL format
        RTSP_URL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('rtsp_url', ''))")
        if [[ $RTSP_URL == rtsp://* ]]; then
            check_pass "RTSP URL format valid"
        else
            check_warn "RTSP URL may be invalid: $RTSP_URL"
        fi
        
    else
        check_fail "Configuration file is not valid JSON"
    fi
else
    check_fail "Configuration file not found at $CONFIG_FILE"
fi

# 6. Check logging
print_header "6. Logging Setup"

LOG_FILES=(
    "/var/log/rtsp_roi_counter.log"
    "/var/log/memory_monitor.log"
)

for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
        if [ -w "$log_file" ]; then
            check_pass "$(basename $log_file) exists and is writable"
        else
            check_fail "$(basename $log_file) exists but is not writable"
        fi
    else
        check_warn "$(basename $log_file) does not exist (will be created on first run)"
    fi
done

# 7. Check systemd service
print_header "7. Systemd Service"

SERVICE_FILE="/etc/systemd/system/rtsp-roi-counter.service"
if [ -f "$SERVICE_FILE" ]; then
    check_pass "Service file exists"
    
    # Check if service is enabled
    if systemctl is-enabled rtsp-roi-counter &> /dev/null; then
        check_pass "Service is enabled for auto-start"
    else
        check_warn "Service is not enabled for auto-start"
        echo "  Enable with: sudo systemctl enable rtsp-roi-counter"
    fi
    
    # Check service status
    if systemctl is-active rtsp-roi-counter &> /dev/null; then
        check_pass "Service is currently running"
    else
        check_warn "Service is not running"
        echo "  Start with: sudo systemctl start rtsp-roi-counter"
    fi
else
    check_warn "Service file not found at $SERVICE_FILE"
fi

# 8. Check system resources
print_header "8. System Resources"

# Memory
TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
if [ "$TOTAL_MEM" -ge 1500 ]; then
    check_pass "Available memory: ${TOTAL_MEM}MB (sufficient)"
else
    check_warn "Available memory: ${TOTAL_MEM}MB (may be insufficient)"
fi

# Disk space
DISK_AVAIL=$(df -h /var | awk 'NR==2 {print $4}')
check_pass "Available disk space in /var: $DISK_AVAIL"

# 9. Network connectivity test
print_header "9. Network Connectivity"

if [ -f "$CONFIG_FILE" ]; then
    RTSP_URL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('rtsp_url', ''))" 2>/dev/null)
    
    if [ -n "$RTSP_URL" ]; then
        # Extract IP from RTSP URL
        RTSP_IP=$(echo "$RTSP_URL" | sed -n 's/.*:\/\/\([^:\/]*\).*/\1/p')
        
        if [ -n "$RTSP_IP" ]; then
            if ping -c 1 -W 2 "$RTSP_IP" &> /dev/null; then
                check_pass "RTSP host $RTSP_IP is reachable"
            else
                check_warn "Cannot ping RTSP host $RTSP_IP (may still work)"
            fi
        fi
    fi
fi

# 10. Summary
print_header "Validation Summary"

echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    echo "System is ready for deployment."
    EXIT_CODE=0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠ $WARNINGS warning(s) found${NC}"
    echo "System should work but review warnings above."
    EXIT_CODE=0
else
    echo -e "${RED}✗ $ERRORS error(s) found${NC}"
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ $WARNINGS warning(s) found${NC}"
    fi
    echo ""
    echo "Please fix errors before deployment."
    EXIT_CODE=1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo "Next steps:"
    echo "1. Start service: sudo systemctl start rtsp-roi-counter"
    echo "2. Check status: sudo systemctl status rtsp-roi-counter"
    echo "3. Monitor logs: sudo journalctl -u rtsp-roi-counter -f"
    echo "4. Check HTTP status: curl http://localhost:8080/status"
fi

exit $EXIT_CODE
