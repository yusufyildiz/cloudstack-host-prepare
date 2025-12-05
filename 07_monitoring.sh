#!/bin/bash
# ==============================================================================
# SCRIPT: 07_monitoring.sh
# DESCRIPTION: Health check and monitoring setup for KVM hosts
# ==============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root${NC}"
   exit 1
fi

CONFIG_FILE="server.conf"
HEALTH_LOG="/var/log/kvm-health.log"
HEALTH_SCRIPT="/usr/local/bin/kvm-health-check.sh"

echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   KVM HOST MONITORING SETUP                     ${NC}"
echo -e "${GREEN}=================================================${NC}"

# Load config if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# ==============================================================================
# HEALTH CHECK SCRIPT INSTALLATION
# ==============================================================================
echo -e "\n${YELLOW}--- Installing Health Check Script ---${NC}"

cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
# KVM Host Health Check Script
# Run manually or via cron

WARN=0
CRIT=0
OUTPUT=""

add_check() {
    local status=$1
    local message=$2
    OUTPUT="${OUTPUT}${message}\n"
    if [ "$status" == "WARN" ]; then ((WARN++)); fi
    if [ "$status" == "CRIT" ]; then ((CRIT++)); fi
}

# 1. Bond Status Check
for bond in bond0 bond1; do
    if [ -f "/proc/net/bonding/$bond" ]; then
        slaves_up=$(grep -c "MII Status: up" "/proc/net/bonding/$bond" 2>/dev/null || echo 0)
        slaves_total=$(grep -c "Slave Interface:" "/proc/net/bonding/$bond" 2>/dev/null || echo 0)
        if [ "$slaves_up" -lt "$slaves_total" ]; then
            add_check "WARN" "[WARN] $bond: $slaves_up/$slaves_total slaves up"
        else
            add_check "OK" "[OK] $bond: $slaves_up/$slaves_total slaves up"
        fi
    fi
done

# 2. Bridge Status Check
for br in cloudbr0 cloudbr1 cloudbr100; do
    if ip link show "$br" &>/dev/null; then
        state=$(ip -br link show "$br" | awk '{print $2}')
        if [ "$state" == "UP" ]; then
            add_check "OK" "[OK] $br: UP"
        else
            add_check "CRIT" "[CRIT] $br: $state"
        fi
    fi
done

# 3. IP Address Check
for br in cloudbr0 cloudbr1; do
    if ip link show "$br" &>/dev/null; then
        ip_addr=$(ip -4 addr show "$br" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        if [ -n "$ip_addr" ]; then
            add_check "OK" "[OK] $br IP: $ip_addr"
        else
            add_check "CRIT" "[CRIT] $br: No IP assigned"
        fi
    fi
done

# 4. Gateway Connectivity
gateway=$(ip route | grep default | awk '{print $3}' | head -1)
if [ -n "$gateway" ]; then
    if ping -c 1 -W 2 "$gateway" &>/dev/null; then
        add_check "OK" "[OK] Gateway $gateway: Reachable"
    else
        add_check "CRIT" "[CRIT] Gateway $gateway: Unreachable"
    fi
fi

# 5. NetworkManager Status
if systemctl is-active --quiet NetworkManager; then
    add_check "OK" "[OK] NetworkManager: Running"
else
    add_check "CRIT" "[CRIT] NetworkManager: Not running"
fi

# 6. libvirtd Status
if systemctl is-active --quiet libvirtd 2>/dev/null; then
    add_check "OK" "[OK] libvirtd: Running"
else
    add_check "WARN" "[WARN] libvirtd: Not running"
fi

# 7. Disk Space Check (root filesystem)
disk_usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$disk_usage" -gt 90 ]; then
    add_check "CRIT" "[CRIT] Disk usage: ${disk_usage}%"
elif [ "$disk_usage" -gt 80 ]; then
    add_check "WARN" "[WARN] Disk usage: ${disk_usage}%"
else
    add_check "OK" "[OK] Disk usage: ${disk_usage}%"
fi

# 8. Memory Check
mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
if [ "$mem_usage" -gt 95 ]; then
    add_check "CRIT" "[CRIT] Memory usage: ${mem_usage}%"
elif [ "$mem_usage" -gt 85 ]; then
    add_check "WARN" "[WARN] Memory usage: ${mem_usage}%"
else
    add_check "OK" "[OK] Memory usage: ${mem_usage}%"
fi

# 9. Load Average Check
cores=$(nproc)
load=$(cat /proc/loadavg | awk '{print $1}')
load_int=${load%.*}
if [ "$load_int" -gt "$((cores * 2))" ]; then
    add_check "CRIT" "[CRIT] Load average: $load (cores: $cores)"
elif [ "$load_int" -gt "$cores" ]; then
    add_check "WARN" "[WARN] Load average: $load (cores: $cores)"
else
    add_check "OK" "[OK] Load average: $load (cores: $cores)"
fi

# Output Results
echo "=========================================="
echo "KVM HOST HEALTH CHECK - $(hostname)"
echo "Date: $(date)"
echo "=========================================="
echo -e "$OUTPUT"
echo "------------------------------------------"
echo "Summary: CRITICAL=$CRIT, WARNING=$WARN"
echo "=========================================="

# Exit code
if [ "$CRIT" -gt 0 ]; then exit 2; fi
if [ "$WARN" -gt 0 ]; then exit 1; fi
exit 0
HEALTHEOF

chmod +x "$HEALTH_SCRIPT"
echo -e "   ${GREEN}✅ Health check script installed: $HEALTH_SCRIPT${NC}"

# ==============================================================================
# CRON JOB SETUP
# ==============================================================================
echo -e "\n${YELLOW}--- Setting up Cron Job ---${NC}"

CRON_FILE="/etc/cron.d/kvm-health-check"
cat > "$CRON_FILE" << EOF
# KVM Host Health Check - runs every 5 minutes
*/5 * * * * root $HEALTH_SCRIPT >> $HEALTH_LOG 2>&1
EOF

echo -e "   ${GREEN}✅ Cron job installed: $CRON_FILE${NC}"

# ==============================================================================
# SYSTEMD SERVICE (Optional - for real-time monitoring)
# ==============================================================================
echo -e "\n${YELLOW}--- Creating Systemd Health Service ---${NC}"

cat > /etc/systemd/system/kvm-health.service << EOF
[Unit]
Description=KVM Host Health Check
After=network.target

[Service]
Type=oneshot
ExecStart=$HEALTH_SCRIPT
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/kvm-health.timer << EOF
[Unit]
Description=Run KVM Health Check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now kvm-health.timer 2>/dev/null || true
echo -e "   ${GREEN}✅ Systemd timer enabled${NC}"

# ==============================================================================
# LOG ROTATION
# ==============================================================================
echo -e "\n${YELLOW}--- Setting up Log Rotation ---${NC}"

cat > /etc/logrotate.d/kvm-health << EOF
$HEALTH_LOG {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

echo -e "   ${GREEN}✅ Log rotation configured${NC}"

# ==============================================================================
# RUN INITIAL CHECK
# ==============================================================================
echo -e "\n${YELLOW}--- Running Initial Health Check ---${NC}\n"
$HEALTH_SCRIPT || true

echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN}   MONITORING SETUP COMPLETE                     ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo "Commands:"
echo "  - Manual check:    $HEALTH_SCRIPT"
echo "  - View logs:       tail -f $HEALTH_LOG"
echo "  - Timer status:    systemctl status kvm-health.timer"
echo ""
