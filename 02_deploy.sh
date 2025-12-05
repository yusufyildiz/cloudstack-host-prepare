#!/bin/bash
# ==============================================================================
# SCRIPT: 02_deploy.sh
# DESCRIPTION: Reads server.conf, deploys network, updates Agent, verifies connection.
# USAGE: ./02_deploy.sh [--dry-run] [--rollback] [--compare] [--backup]
# ==============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CONFIG_FILE="server.conf"
LOG_FILE="/var/log/network_deploy.log"
AGENT_PROP="/etc/cloudstack/agent/agent.properties"
BACKUP_DIR="/var/backup/network-config"

# Flags
DRY_RUN=false
DO_ROLLBACK=false
DO_COMPARE=false
DO_BACKUP=false

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would be done without making changes"
    echo "  --rollback    Restore network from last backup"
    echo "  --compare     Compare current config with server.conf"
    echo "  --backup      Backup current network config only"
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  # Deploy network configuration"
    echo "  $0 --dry-run        # Preview changes without applying"
    echo "  $0 --rollback       # Restore from backup"
    echo "  $0 --compare        # Show differences"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --rollback)
            DO_ROLLBACK=true
            shift
            ;;
        --compare)
            DO_COMPARE=true
            shift
            ;;
        --backup)
            DO_BACKUP=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            ;;
    esac
done

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
log() {
    echo -e "$1"
    [ "$DRY_RUN" = false ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

run_cmd() {
    local cmd="$1"
    local desc="${2:-}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}[DRY-RUN]${NC} $cmd"
    else
        [ -n "$desc" ] && log "   $desc"
        eval "$cmd"
    fi
}

# ==============================================================================
# BACKUP FUNCTIONS
# ==============================================================================
backup_network_config() {
    local backup_file="$BACKUP_DIR/network-$(date +%Y%m%d-%H%M%S).tar.gz"

    log "${YELLOW}--- Creating Network Backup ---${NC}"
    mkdir -p "$BACKUP_DIR"

    # Export nmcli connections
    local tmp_dir=$(mktemp -d)
    nmcli -t -f NAME connection show | while read conn; do
        nmcli connection export "$conn" > "$tmp_dir/${conn}.nmconnection" 2>/dev/null || true
    done

    # Save current state
    ip addr > "$tmp_dir/ip-addr.txt"
    ip route > "$tmp_dir/ip-route.txt"
    nmcli connection show > "$tmp_dir/nmcli-connections.txt"

    # Copy agent properties if exists
    [ -f "$AGENT_PROP" ] && cp "$AGENT_PROP" "$tmp_dir/"

    # Create archive
    tar -czf "$backup_file" -C "$tmp_dir" . 2>/dev/null
    rm -rf "$tmp_dir"

    # Keep only last 5 backups
    ls -t "$BACKUP_DIR"/network-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm

    log "${GREEN}✅ Backup created: $backup_file${NC}"
    echo "$backup_file"
}

restore_from_backup() {
    log "${YELLOW}=== NETWORK ROLLBACK ===${NC}"

    # Find latest backup
    local latest_backup=$(ls -t "$BACKUP_DIR"/network-*.tar.gz 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        log "${RED}ERROR: No backup found in $BACKUP_DIR${NC}"
        exit 1
    fi

    log "Restoring from: $latest_backup"

    local tmp_dir=$(mktemp -d)
    tar -xzf "$latest_backup" -C "$tmp_dir"

    # Delete current connections
    log "Removing current connections..."
    nmcli -t -f UUID,NAME connection show | grep -E "cloudbr|bond|vlan|rescue" | cut -d: -f1 | while read uuid; do
        nmcli connection delete "$uuid" 2>/dev/null || true
    done

    # Restore connections
    log "Restoring connections..."
    for conn_file in "$tmp_dir"/*.nmconnection; do
        [ -f "$conn_file" ] && nmcli connection load "$conn_file" 2>/dev/null || true
    done

    # Restore agent properties
    [ -f "$tmp_dir/agent.properties" ] && cp "$tmp_dir/agent.properties" "$AGENT_PROP"

    rm -rf "$tmp_dir"

    # Activate connections
    log "Activating restored connections..."
    for conn in bond0 bond1 cloudbr0 cloudbr1 cloudbr100; do
        nmcli connection up "$conn" 2>/dev/null || true
    done

    log "${GREEN}✅ Rollback complete${NC}"
}

# ==============================================================================
# COMPARE FUNCTION
# ==============================================================================
compare_config() {
    log "${YELLOW}=== CONFIGURATION COMPARISON ===${NC}"
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then
        log "${RED}ERROR: $CONFIG_FILE not found${NC}"
        exit 1
    fi

    source "$CONFIG_FILE"

    echo -e "${CYAN}Parameter           | server.conf          | Current System${NC}"
    echo "--------------------+----------------------+----------------------"

    # Hostname
    current_hostname=$(hostname)
    if [ "$MY_HOSTNAME" == "$current_hostname" ]; then
        echo -e "Hostname            | $MY_HOSTNAME | ${GREEN}$current_hostname${NC}"
    else
        echo -e "Hostname            | $MY_HOSTNAME | ${RED}$current_hostname${NC}"
    fi

    # Storage IP
    current_strg_ip=$(ip -4 addr show cloudbr0 2>/dev/null | grep -oP 'inet \K[\d./]+' || echo "N/A")
    if [ "$MY_STRG_IP" == "$current_strg_ip" ]; then
        echo -e "Storage IP          | $MY_STRG_IP | ${GREEN}$current_strg_ip${NC}"
    else
        echo -e "Storage IP          | $MY_STRG_IP | ${RED}$current_strg_ip${NC}"
    fi

    # Management IP
    current_mgmt_ip=$(ip -4 addr show cloudbr1 2>/dev/null | grep -oP 'inet \K[\d./]+' || echo "N/A")
    if [ "$MY_MGMT_IP" == "$current_mgmt_ip" ]; then
        echo -e "Management IP       | $MY_MGMT_IP | ${GREEN}$current_mgmt_ip${NC}"
    else
        echo -e "Management IP       | $MY_MGMT_IP | ${RED}$current_mgmt_ip${NC}"
    fi

    # Storage Mode
    if [ "$STRG_MODE" == "tagged" ]; then
        if ip link show "bond0.${VLAN_STORAGE}" &>/dev/null; then
            echo -e "Storage Mode        | tagged (VLAN $VLAN_STORAGE) | ${GREEN}tagged${NC}"
        else
            echo -e "Storage Mode        | tagged (VLAN $VLAN_STORAGE) | ${RED}untagged${NC}"
        fi
    else
        if ip link show "bond0" &>/dev/null && ! ip link show "bond0.*" &>/dev/null 2>&1; then
            echo -e "Storage Mode        | untagged | ${GREEN}untagged${NC}"
        else
            echo -e "Storage Mode        | untagged | ${RED}tagged${NC}"
        fi
    fi

    # Management Mode
    if [ "$MGMT_MODE" == "tagged" ]; then
        if ip link show "bond1.${VLAN_MGMT}" &>/dev/null; then
            echo -e "Management Mode     | tagged (VLAN $VLAN_MGMT) | ${GREEN}tagged${NC}"
        else
            echo -e "Management Mode     | tagged (VLAN $VLAN_MGMT) | ${RED}untagged${NC}"
        fi
    else
        echo -e "Management Mode     | untagged | Current: check manually"
    fi

    # MTU
    current_mtu_bond0=$(ip link show bond0 2>/dev/null | grep -oP 'mtu \K\d+' || echo "N/A")
    if [ "$MTU_JUMBO" == "$current_mtu_bond0" ]; then
        echo -e "Storage MTU         | $MTU_JUMBO | ${GREEN}$current_mtu_bond0${NC}"
    else
        echo -e "Storage MTU         | $MTU_JUMBO | ${RED}$current_mtu_bond0${NC}"
    fi

    echo ""
}

# ==============================================================================
# EMERGENCY ROLLBACK FUNCTION
# ==============================================================================
emergency_rollback() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! CRITICAL FAILURE: CONNECTIVITY LOST - INITIATING ROLLBACK !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    # Clean up potentially broken bridges
    nmcli connection delete cloudbr1 2>/dev/null || true

    echo "Creating Emergency Interface (rescue-mgmt)..."

    if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_MGMT" ]; then
        nmcli connection delete "bond1.$VLAN_MGMT" 2>/dev/null || true
        nmcli connection add type vlan ifname "bond1.$VLAN_MGMT" dev bond1 id "$VLAN_MGMT" \
            con-name "rescue-mgmt" \
            ipv4.method manual ipv4.addresses "$MY_MGMT_IP" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" \
            mtu "$MTU_STD"
    else
        nmcli connection add type ethernet ifname bond1 \
            con-name "rescue-mgmt" \
            ipv4.method manual ipv4.addresses "$MY_MGMT_IP" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" \
            mtu "$MTU_STD"
    fi

    nmcli connection up "rescue-mgmt"
    echo "Rollback Complete. Server reachable via 'rescue-mgmt'."
    exit 1
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

# Root check (except for --help)
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root${NC}"
   exit 1
fi

# Handle special modes
if [ "$DO_ROLLBACK" = true ]; then
    restore_from_backup
    exit 0
fi

if [ "$DO_COMPARE" = true ]; then
    compare_config
    exit 0
fi

if [ "$DO_BACKUP" = true ]; then
    backup_network_config
    exit 0
fi

# Redirect output to log file (only in normal mode)
if [ "$DRY_RUN" = false ]; then
    exec > >(tee -a ${LOG_FILE}) 2>&1
fi

# Header
if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}   DRY-RUN MODE - No changes will be made        ${NC}"
    echo -e "${CYAN}=================================================${NC}"
else
    echo "=== [$(date)] Deployment Started ==="
fi

# 1. PRE-CHECKS & VALIDATION
if [ ! -f "$CONFIG_FILE" ]; then
    log "${RED}CRITICAL ERROR: '$CONFIG_FILE' not found! Run 01_discovery.sh first.${NC}"
    exit 1
fi
source "$CONFIG_FILE"

# Validation
if [[ "$MY_MGMT_IP" == *"MANUAL"* ]] || [[ "$MY_STRG_IP" == *"MANUAL"* ]]; then
    log "${RED}ERROR: IP addresses are missing in server.conf. Please edit the file.${NC}"
    exit 1
fi

# Validate mode settings
STRG_MODE=${STRG_MODE:-"untagged"}
MGMT_MODE=${MGMT_MODE:-"tagged"}

log "${YELLOW}Target Configuration ($MY_HOSTNAME):${NC}"
log "  - Storage: $MY_STRG_IP (Mode: $STRG_MODE, VLAN: ${VLAN_STORAGE:-N/A})"
log "  - Mgmt:    $MY_MGMT_IP (Mode: $MGMT_MODE, VLAN: ${VLAN_MGMT:-N/A})"
log "  - Public:  VLAN ${VLAN_PUBLIC:-N/A}"
log "  - Ports:   Storage=[$MY_BOND0_SLAVES] | Mgmt=[$MY_BOND1_SLAVES]"

# Create backup before making changes
if [ "$DRY_RUN" = false ]; then
    backup_network_config
fi

# ==============================================================================
# 2. EXECUTION (Cleanup & Setup)
# ==============================================================================
log "${YELLOW}--- Starting Configuration in 5 Seconds... ---${NC}"
[ "$DRY_RUN" = false ] && sleep 5

run_cmd "hostnamectl set-hostname \"$MY_HOSTNAME\"" "Setting hostname"

# CLEANUP
log "${YELLOW}Cleaning up old connections...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY-RUN]${NC} Would delete existing cloudbr/bond/vlan connections"
else
    nmcli -t -f UUID,NAME connection show | grep -E "cloudbr|bond|vlan|rescue" | cut -d: -f1 | while read uuid; do
        nmcli connection delete "$uuid" 2>/dev/null || true
    done
    for iface in $MY_BOND0_SLAVES $MY_BOND1_SLAVES; do
        nmcli connection delete "$iface" 2>/dev/null || true
    done
fi

# ==============================================================================
# A. STORAGE NETWORK (bond0 -> cloudbr0)
# ==============================================================================
log "${YELLOW}--- Deploying Storage Network (Mode: $STRG_MODE, MTU: $MTU_JUMBO) ---${NC}"

run_cmd "nmcli connection add type bond ifname bond0 con-name bond0 bond.options \"mode=802.3ad,miimon=100,lacp_rate=fast\" mtu \"$MTU_JUMBO\" connection.autoconnect yes" "Creating bond0"

for slave in $MY_BOND0_SLAVES; do
    run_cmd "nmcli connection add type ethernet ifname \"$slave\" master bond0 con-name \"bond0-slave-$slave\" mtu \"$MTU_JUMBO\" connection.autoconnect yes" "Adding slave $slave to bond0"
done

run_cmd "nmcli connection add type bridge ifname cloudbr0 con-name cloudbr0 bridge.stp no mtu \"$MTU_JUMBO\" connection.autoconnect yes" "Creating cloudbr0"
run_cmd "nmcli connection modify cloudbr0 ipv4.method manual ipv4.addresses \"$MY_STRG_IP\"" "Assigning IP to cloudbr0"

if [ "$STRG_MODE" == "tagged" ] && [ -n "$VLAN_STORAGE" ]; then
    log "   Creating VLAN $VLAN_STORAGE interface for storage..."
    run_cmd "nmcli connection add type vlan ifname \"bond0.$VLAN_STORAGE\" dev bond0 id \"$VLAN_STORAGE\" master cloudbr0 slave-type bridge con-name \"bond0.$VLAN_STORAGE-bridge\" mtu \"$MTU_JUMBO\" connection.autoconnect yes"
else
    log "   Attaching bond0 directly to cloudbr0 (untagged)..."
    run_cmd "nmcli connection modify bond0 master cloudbr0"
fi

# ==============================================================================
# B. MANAGEMENT & PUBLIC NETWORK (bond1)
# ==============================================================================
log "${YELLOW}--- Deploying Management & Public Network (Mode: $MGMT_MODE, MTU: $MTU_STD) ---${NC}"

run_cmd "nmcli connection add type bond ifname bond1 con-name bond1 bond.options \"mode=802.3ad,miimon=100,lacp_rate=fast\" mtu \"$MTU_STD\" connection.autoconnect yes" "Creating bond1"

for slave in $MY_BOND1_SLAVES; do
    run_cmd "nmcli connection add type ethernet ifname \"$slave\" master bond1 con-name \"bond1-slave-$slave\" mtu \"$MTU_STD\" connection.autoconnect yes" "Adding slave $slave to bond1"
done

run_cmd "nmcli connection add type bridge ifname cloudbr1 con-name cloudbr1 bridge.stp no mtu \"$MTU_STD\" connection.autoconnect yes" "Creating cloudbr1"
run_cmd "nmcli connection modify cloudbr1 ipv4.method manual ipv4.addresses \"$MY_MGMT_IP\" ipv4.gateway \"$GATEWAY\" ipv4.dns \"$DNS\"" "Configuring cloudbr1"

if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_MGMT" ]; then
    log "   Creating VLAN $VLAN_MGMT interface for management..."
    run_cmd "nmcli connection add type vlan ifname \"bond1.$VLAN_MGMT\" dev bond1 id \"$VLAN_MGMT\" master cloudbr1 slave-type bridge con-name \"bond1.$VLAN_MGMT-bridge\" mtu \"$MTU_STD\" connection.autoconnect yes"

    if [ -n "$VLAN_PUBLIC" ]; then
        log "   Creating VLAN $VLAN_PUBLIC interface for public..."
        run_cmd "nmcli connection add type bridge ifname cloudbr100 con-name cloudbr100 bridge.stp no mtu \"$MTU_STD\" connection.autoconnect yes"
        run_cmd "nmcli connection modify cloudbr100 ipv4.method disabled ipv6.method disabled"
        run_cmd "nmcli connection add type vlan ifname \"bond1.$VLAN_PUBLIC\" dev bond1 id \"$VLAN_PUBLIC\" master cloudbr100 slave-type bridge con-name \"bond1.$VLAN_PUBLIC-bridge\" mtu \"$MTU_STD\" connection.autoconnect yes"
    fi
else
    log "   Attaching bond1 directly to cloudbr1 (untagged)..."
    run_cmd "nmcli connection modify bond1 master cloudbr1"
fi

# ==============================================================================
# C. CLOUDSTACK AGENT CONFIGURATION
# ==============================================================================
log "${YELLOW}--- Updating CloudStack Agent Properties ---${NC}"

update_prop() {
    local key=$1
    local value=$2
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}[DRY-RUN]${NC} Would set $key=$value"
    else
        if grep -q "^${key}=" "$AGENT_PROP"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$AGENT_PROP"
        elif grep -q "^#${key}=" "$AGENT_PROP"; then
            sed -i "s|^#${key}=.*|${key}=${value}|" "$AGENT_PROP"
        else
            echo "${key}=${value}" >> "$AGENT_PROP"
        fi
    fi
}

if [ -f "$AGENT_PROP" ] || [ "$DRY_RUN" = true ]; then
    [ "$DRY_RUN" = false ] && cp "$AGENT_PROP" "${AGENT_PROP}.bak"
    update_prop "private.network.device" "cloudbr1"
    if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_PUBLIC" ]; then
        update_prop "public.network.device" "cloudbr100"
    else
        update_prop "public.network.device" "cloudbr1"
    fi
    update_prop "guest.network.device" "bond1"
    update_prop "network.bridge.type" "native"
    log "Agent properties updated."
else
    log "${YELLOW}WARNING: Agent properties file not found. Skipping.${NC}"
fi

# ==============================================================================
# 3. ACTIVATION & VERIFICATION
# ==============================================================================
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}   DRY-RUN COMPLETE - No changes were made       ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo ""
    echo "To apply these changes, run: $0"
    exit 0
fi

log "${YELLOW}--- Activating Connections ---${NC}"

for slave in $MY_BOND0_SLAVES; do
    nmcli connection up "bond0-slave-$slave" 2>/dev/null || true
done

for slave in $MY_BOND1_SLAVES; do
    nmcli connection up "bond1-slave-$slave" 2>/dev/null || true
done

nmcli connection up bond0
nmcli connection up cloudbr0
nmcli connection up bond1
nmcli connection up cloudbr1

if nmcli connection show cloudbr100 &>/dev/null; then
    nmcli connection up cloudbr100
fi

log "${YELLOW}--- Verifying Connectivity (Waiting 20s) ---${NC}"
sleep 20

if ping -c 3 -W 2 "$GATEWAY"; then
    log "${GREEN}SUCCESS: Network Deployed & Gateway Reachable.${NC}"
    echo "------------------------------------------------"
    ip -br a | grep -E "cloudbr|bond"
    echo "------------------------------------------------"
    log "Restarting CloudStack Agent..."
    systemctl restart cloudstack-agent || log "${YELLOW}WARNING: CloudStack agent restart failed or not installed.${NC}"
else
    emergency_rollback
fi
