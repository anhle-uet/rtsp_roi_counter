#!/bin/bash
#
# RTSP ROI Counter - Quick Installation Script
# Automates the installation process
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RTSP ROI Counter - Quick Installation"
echo "  For Raspberry Pi 5 + Hailo-8"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    echo -e "${RED}Please do not run this script as root${NC}"
    echo "Run as: ./quick_install.sh"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths
INSTALL_DIR="/home/orbro/rtsp_roi_counter"
CONFIG_DIR="/etc/rtsp_roi_counter"
HAILO_APPS="/home/orbro/workspace/projects/hailo-rpi5-examples"

echo -e "${BLUE}Installation Configuration:${NC}"
echo "  Install directory: $INSTALL_DIR"
echo "  Config directory: $CONFIG_DIR"
echo "  Hailo apps: $HAILO_APPS"
echo ""

# Ask for confirmation
read -p "Continue with installation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Step 1: Installing system dependencies...${NC}"
sudo apt-get update
sudo apt-get install -y python3 python3-gi gstreamer1.0-tools \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
    gstreamer1.0-rtsp bc jq curl

echo ""
echo -e "${GREEN}✓ Dependencies installed${NC}"

echo ""
echo -e "${BLUE}Step 2: Creating application directory...${NC}"
sudo mkdir -p "$INSTALL_DIR"
sudo chown -R $USER:$USER "$INSTALL_DIR"

# Copy application files
cp "$SCRIPT_DIR/rtsp_roi_counter.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/memory_monitor_wrapper.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/monitor_dashboard.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/validate_installation.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/README.md" "$INSTALL_DIR/" || true
cp "$SCRIPT_DIR/DEPLOYMENT_GUIDE.md" "$INSTALL_DIR/" || true

# Make scripts executable
chmod +x "$INSTALL_DIR"/*.sh
chmod +x "$INSTALL_DIR"/*.py

echo -e "${GREEN}✓ Application files installed${NC}"

echo ""
echo -e "${BLUE}Step 3: Creating configuration directory...${NC}"
sudo mkdir -p "$CONFIG_DIR"

# Check if config already exists
if [ -f "$CONFIG_DIR/config.json" ]; then
    echo -e "${YELLOW}⚠ Configuration file already exists${NC}"
    read -p "Backup and replace with example? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo cp "$CONFIG_DIR/config.json" "$CONFIG_DIR/config.json.backup"
        echo "  Backed up to config.json.backup"
        sudo cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
    fi
else
    sudo cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
fi

echo -e "${GREEN}✓ Configuration directory created${NC}"

echo ""
echo -e "${BLUE}Step 4: Setting up logging...${NC}"
sudo touch /var/log/rtsp_roi_counter.log
sudo touch /var/log/memory_monitor.log
sudo chown $USER:$USER /var/log/rtsp_roi_counter.log
sudo chown $USER:$USER /var/log/memory_monitor.log

echo -e "${GREEN}✓ Log files created${NC}"

echo ""
echo -e "${BLUE}Step 5: Configuring systemd service...${NC}"

# Check if Hailo apps exist
if [ ! -d "$HAILO_APPS" ]; then
    echo -e "${YELLOW}⚠ Warning: hailo_apps_infra not found at $HAILO_APPS${NC}"
    echo "  You may need to adjust paths in the service file"
fi

# Create service file with current paths
cat > /tmp/rtsp-roi-counter.service << EOF
[Unit]
Description=RTSP ROI Counter - Hailo Object Detection
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=200
StartLimitBurst=5

[Service]
Type=simple
User=orbro
Group=orbro
WorkingDirectory=$INSTALL_DIR

# Source Hailo environment then run the application
ExecStartPre=/bin/bash -c 'test -f $HAILO_APPS/setup_env.sh'
ExecStart=/bin/bash -c 'source $HAILO_APPS/setup_env.sh && $INSTALL_DIR/memory_monitor_wrapper.sh $CONFIG_DIR/config.json 1500'

# Restart configuration
Restart=always
RestartSec=10

# Resource limits for Pi5 with 2GB RAM
MemoryMax=1800M
MemoryHigh=1600M

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rtsp-roi-counter

# Security
NoNewPrivileges=true
PrivateTmp=true

# Environment
Environment="PYTHONUNBUFFERED=1"
Environment="GST_DEBUG=2"

[Install]
WantedBy=multi-user.target
EOF

sudo cp /tmp/rtsp-roi-counter.service /etc/systemd/system/
sudo systemctl daemon-reload

echo -e "${GREEN}✓ Systemd service configured${NC}"

echo ""
echo -e "${BLUE}Step 6: Running validation...${NC}"
cd "$INSTALL_DIR"
if ./validate_installation.sh; then
    echo ""
    echo -e "${GREEN}✓ Validation passed!${NC}"
else
    echo ""
    echo -e "${YELLOW}⚠ Some validation checks failed${NC}"
    echo "  Review the output above and fix any errors"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Installation Complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${YELLOW}IMPORTANT: Before starting the service${NC}"
echo ""
echo "1. Edit the configuration file:"
echo "   sudo nano $CONFIG_DIR/config.json"
echo ""
echo "   Update these fields:"
echo "   - rtsp_url: Your camera's RTSP URL"
echo "   - hef_path: Path to your Hailo model"
echo "   - postprocess_so: Path to postprocess library"
echo "   - roi: Define your region of interest"
echo ""
echo "2. Test the configuration manually:"
echo "   cd $HAILO_APPS"
echo "   source setup_env.sh"
echo "   cd $INSTALL_DIR"
echo "   python3 rtsp_roi_counter.py $CONFIG_DIR/config.json"
echo ""
echo "3. If the test works, enable and start the service:"
echo "   sudo systemctl enable rtsp-roi-counter"
echo "   sudo systemctl start rtsp-roi-counter"
echo ""
echo "4. Monitor the service:"
echo "   sudo systemctl status rtsp-roi-counter"
echo "   sudo journalctl -u rtsp-roi-counter -f"
echo "   curl http://localhost:8080/status"
echo ""
echo "5. Use the monitoring dashboard:"
echo "   $INSTALL_DIR/monitor_dashboard.sh"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Documentation:"
echo "  README: $INSTALL_DIR/README.md"
echo "  Full Guide: $INSTALL_DIR/DEPLOYMENT_GUIDE.md"
echo ""
echo "Configuration file: $CONFIG_DIR/config.json"
echo "Application logs: /var/log/rtsp_roi_counter.log"
echo "Memory logs: /var/log/memory_monitor.log"
echo ""
