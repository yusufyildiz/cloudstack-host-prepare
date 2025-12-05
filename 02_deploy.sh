#!/bin/bash
# ==============================================================================
# SCRIPT: 02_deploy.sh
# DESCRIPTION: Reads server.conf, deploys network, updates Agent, verifies connection.
# USAGE: nohup ./02_deploy.sh &
# ==============================================================================

set -euo pipefail

# Root check
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root"
   exit 1
fi

CONFIG_FILE="server.conf"
LOG_FILE="/var/log/network_deploy.log"
AGENT_PROP="/etc/cloudstack/agent/agent.properties"

# Redirect output to log file
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "=== [$(date)] Deployment Started ==="

# 1. PRE-CHECKS & VALIDATION
if [ ! -f "$CONFIG_FILE" ]; then
    echo "CRITICAL ERROR: '$CONFIG_FILE' not found! Run 01_discovery.sh first."
    exit 1
fi
source "$CONFIG_FILE"

# Validation
if [[ "$MY_MGMT_IP" == *"MANUAL"* ]] || [[ "$MY_STRG_IP" == *"MANUAL"* ]]; then
    echo "ERROR: IP addresses are missing in server.conf. Please edit the file."
    exit 1
fi

# Validate mode settings
STRG_MODE=${STRG_MODE:-"untagged"}
MGMT_MODE=${MGMT_MODE:-"tagged"}

echo "Target Configuration ($MY_HOSTNAME):"
echo "  - Storage: $MY_STRG_IP (Mode: $STRG_MODE, VLAN: ${VLAN_STORAGE:-N/A})"
echo "  - Mgmt:    $MY_MGMT_IP (Mode: $MGMT_MODE, VLAN: ${VLAN_MGMT:-N/A})"
echo "  - Public:  VLAN ${VLAN_PUBLIC:-N/A}"
echo "  - Ports:   Storage=[$MY_BOND0_SLAVES] | Mgmt=[$MY_BOND1_SLAVES]"

# ==========================================
# FAILBACK MECHANISM (SSH Recovery)
# ==========================================
rollback() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! CRITICAL FAILURE: CONNECTIVITY LOST - INITIATING ROLLBACK !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    # Clean up potentially broken bridges
    nmcli connection delete cloudbr1 2>/dev/null || true

    echo "Creating Emergency Interface (rescue-mgmt)..."

    if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_MGMT" ]; then
        # Tagged mode: create VLAN interface
        nmcli connection delete "bond1.$VLAN_MGMT" 2>/dev/null || true
        nmcli connection add type vlan ifname "bond1.$VLAN_MGMT" dev bond1 id "$VLAN_MGMT" \
            con-name "rescue-mgmt" \
            ipv4.method manual ipv4.addresses "$MY_MGMT_IP" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" \
            mtu "$MTU_STD"
    else
        # Untagged mode: direct interface
        nmcli connection add type ethernet ifname bond1 \
            con-name "rescue-mgmt" \
            ipv4.method manual ipv4.addresses "$MY_MGMT_IP" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" \
            mtu "$MTU_STD"
    fi

    nmcli connection up "rescue-mgmt"
    echo "Rollback Complete. Server reachable via 'rescue-mgmt'."
    exit 1
}

# ==========================================
# 2. EXECUTION (Cleanup & Setup)
# ==========================================
echo "--- Starting Configuration in 5 Seconds... ---"
sleep 5

hostnamectl set-hostname "$MY_HOSTNAME"

# CLEANUP
echo "Cleaning up old connections..."
nmcli -t -f UUID,NAME connection show | grep -E "cloudbr|bond|vlan|rescue" | cut -d: -f1 | while read uuid; do
  nmcli connection delete "$uuid" 2>/dev/null || true
done
for iface in $MY_BOND0_SLAVES $MY_BOND1_SLAVES; do
  nmcli connection delete "$iface" 2>/dev/null || true
done

# ==========================================
# A. STORAGE NETWORK (bond0 -> cloudbr0)
# ==========================================
echo "--- Deploying Storage Network (Mode: $STRG_MODE, MTU: $MTU_JUMBO) ---"

# Bond0 Master
nmcli connection add type bond ifname bond0 con-name bond0 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast" mtu "$MTU_JUMBO" connection.autoconnect yes

# Bond0 Slaves
for slave in $MY_BOND0_SLAVES; do
    nmcli connection add type ethernet ifname "$slave" master bond0 con-name "bond0-slave-$slave" mtu "$MTU_JUMBO" connection.autoconnect yes
done

# Cloudbr0 Bridge
nmcli connection add type bridge ifname cloudbr0 con-name cloudbr0 bridge.stp no mtu "$MTU_JUMBO" connection.autoconnect yes
nmcli connection modify cloudbr0 ipv4.method manual ipv4.addresses "$MY_STRG_IP"

if [ "$STRG_MODE" == "tagged" ] && [ -n "$VLAN_STORAGE" ]; then
    # Tagged: bond0 -> VLAN interface -> cloudbr0
    echo "   Creating VLAN $VLAN_STORAGE interface for storage..."
    nmcli connection add type vlan ifname "bond0.$VLAN_STORAGE" dev bond0 id "$VLAN_STORAGE" \
        master cloudbr0 slave-type bridge con-name "bond0.$VLAN_STORAGE-bridge" mtu "$MTU_JUMBO" connection.autoconnect yes
else
    # Untagged: bond0 -> cloudbr0 directly
    echo "   Attaching bond0 directly to cloudbr0 (untagged)..."
    nmcli connection modify bond0 master cloudbr0
fi

# ==========================================
# B. MANAGEMENT & PUBLIC NETWORK (bond1)
# ==========================================
echo "--- Deploying Management & Public Network (Mode: $MGMT_MODE, MTU: $MTU_STD) ---"

# Bond1 Master
nmcli connection add type bond ifname bond1 con-name bond1 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast" mtu "$MTU_STD" connection.autoconnect yes

# Bond1 Slaves
for slave in $MY_BOND1_SLAVES; do
    nmcli connection add type ethernet ifname "$slave" master bond1 con-name "bond1-slave-$slave" mtu "$MTU_STD" connection.autoconnect yes
done

# Management Bridge (cloudbr1)
nmcli connection add type bridge ifname cloudbr1 con-name cloudbr1 bridge.stp no mtu "$MTU_STD" connection.autoconnect yes
nmcli connection modify cloudbr1 ipv4.method manual ipv4.addresses "$MY_MGMT_IP" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS"

if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_MGMT" ]; then
    # Tagged: bond1 -> VLAN interfaces -> bridges
    echo "   Creating VLAN $VLAN_MGMT interface for management..."
    nmcli connection add type vlan ifname "bond1.$VLAN_MGMT" dev bond1 id "$VLAN_MGMT" \
        master cloudbr1 slave-type bridge con-name "bond1.$VLAN_MGMT-bridge" mtu "$MTU_STD" connection.autoconnect yes

    # Public Bridge (cloudbr100)
    if [ -n "$VLAN_PUBLIC" ]; then
        echo "   Creating VLAN $VLAN_PUBLIC interface for public..."
        nmcli connection add type bridge ifname cloudbr100 con-name cloudbr100 bridge.stp no mtu "$MTU_STD" connection.autoconnect yes
        nmcli connection modify cloudbr100 ipv4.method disabled ipv6.method disabled
        nmcli connection add type vlan ifname "bond1.$VLAN_PUBLIC" dev bond1 id "$VLAN_PUBLIC" \
            master cloudbr100 slave-type bridge con-name "bond1.$VLAN_PUBLIC-bridge" mtu "$MTU_STD" connection.autoconnect yes
    fi
else
    # Untagged: bond1 -> cloudbr1 directly
    echo "   Attaching bond1 directly to cloudbr1 (untagged)..."
    nmcli connection modify bond1 master cloudbr1
fi

# ==========================================
# C. CLOUDSTACK AGENT CONFIGURATION
# ==========================================
echo "--- Updating CloudStack Agent Properties ---"

update_prop() {
    local key=$1
    local value=$2
    if grep -q "^${key}=" "$AGENT_PROP"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$AGENT_PROP"
    elif grep -q "^#${key}=" "$AGENT_PROP"; then
        sed -i "s|^#${key}=.*|${key}=${value}|" "$AGENT_PROP"
    else
        echo "${key}=${value}" >> "$AGENT_PROP"
    fi
}

if [ -f "$AGENT_PROP" ]; then
    cp "$AGENT_PROP" "${AGENT_PROP}.bak"
    update_prop "private.network.device" "cloudbr1"
    if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_PUBLIC" ]; then
        update_prop "public.network.device" "cloudbr100"
    else
        update_prop "public.network.device" "cloudbr1"
    fi
    update_prop "guest.network.device" "bond1"
    update_prop "network.bridge.type" "native"
    echo "Agent properties updated."
else
    echo "WARNING: Agent properties file not found. Skipping."
fi

# ==========================================
# 3. ACTIVATION & VERIFICATION
# ==========================================
echo "--- Activating Connections ---"

# Activate bond0 slaves
for slave in $MY_BOND0_SLAVES; do
    nmcli connection up "bond0-slave-$slave" 2>/dev/null || true
done

# Activate bond1 slaves
for slave in $MY_BOND1_SLAVES; do
    nmcli connection up "bond1-slave-$slave" 2>/dev/null || true
done

nmcli connection up bond0
nmcli connection up cloudbr0
nmcli connection up bond1
nmcli connection up cloudbr1

# Activate cloudbr100 if it exists
if nmcli connection show cloudbr100 &>/dev/null; then
    nmcli connection up cloudbr100
fi

echo "--- Verifying Connectivity (Waiting 20s) ---"
sleep 20

if ping -c 3 -W 2 "$GATEWAY"; then
    echo "SUCCESS: Network Deployed & Gateway Reachable."
    echo "------------------------------------------------"
    ip -br a | grep -E "cloudbr|bond"
    echo "------------------------------------------------"
    echo "Restarting CloudStack Agent..."
    systemctl restart cloudstack-agent || echo "WARNING: CloudStack agent restart failed or not installed."
else
    rollback
fi
