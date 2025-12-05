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
    echo "CRITICAL ERROR: '$CONFIG_FILE' not found! Run 01_discover.sh first."
    exit 1
fi
source "$CONFIG_FILE"

# Validation
if [[ "$MY_MGMT_IP" == *"MANUAL"* ]] || [[ "$MY_STRG_IP" == *"MANUAL"* ]]; then
    echo "ERROR: IP addresses are missing in server.conf. Please edit the file."
    exit 1
fi

echo "Target Configuration ($MY_HOSTNAME):"
echo "  - Storage: $MY_STRG_IP (Ports: $MY_BOND0_SLAVES)"
echo "  - Mgmt:    $MY_MGMT_IP (Ports: $MY_BOND1_SLAVES)"

# ==========================================
# FAILBACK MECHANISM (SSH Recovery)
# ==========================================
rollback() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! CRITICAL FAILURE: CONNECTIVITY LOST - INITIATING ROLLBACK !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    
    # Clean up potentially broken bridges
    nmcli connection delete cloudbr1 2>/dev/null
    nmcli connection delete bond1.$VLAN_MGMT 2>/dev/null
    
    # Create simple VLAN interface for SSH recovery
    echo "🚑 Creating Emergency Interface (rescue-mgmt)..."
    nmcli connection add type vlan ifname bond1.$VLAN_MGMT dev bond1 id $VLAN_MGMT \
        con-name "rescue-mgmt" \
        ipv4.method manual ipv4.addresses $MY_MGMT_IP ipv4.gateway $GATEWAY ipv4.dns "$DNS" \
        mtu $MTU_STD
    
    nmcli connection up "rescue-mgmt"
    echo "✅ Rollback Complete. Server reachable via 'rescue-mgmt'."
    exit 1
}

# ==========================================
# 2. EXECUTION (Cleanup & Setup)
# ==========================================
echo "--- Starting Configuration in 5 Seconds... ---"
sleep 5

hostnamectl set-hostname $MY_HOSTNAME

# CLEANUP
echo "Cleaning up old connections..."
nmcli -t -f UUID,NAME connection show | grep -E "cloudbr|bond|vlan|rescue" | cut -d: -f1 | while read uuid; do
  nmcli connection delete "$uuid" 2>/dev/null || true
done
for iface in $MY_BOND0_SLAVES $MY_BOND1_SLAVES; do
  nmcli connection delete "$iface" 2>/dev/null
done

# --- A. STORAGE NETWORK (bond0 -> cloudbr0) ---
# Logic: Access Port on Switch (Untagged) -> Direct Bridge
echo "--- Deploying Storage Network (MTU $MTU_JUMBO) ---"

# Bond0 Master
nmcli connection add type bond ifname bond0 con-name bond0 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast" mtu $MTU_JUMBO connection.autoconnect yes

# Bond0 Slaves
for slave in $MY_BOND0_SLAVES; do
    nmcli connection add type ethernet ifname $slave master bond0 con-name "bond0-slave-$slave" mtu $MTU_JUMBO connection.autoconnect yes
done

# Cloudbr0 (IP Assigned Here)
nmcli connection add type bridge ifname cloudbr0 con-name cloudbr0 bridge.stp no mtu $MTU_JUMBO connection.autoconnect yes
nmcli connection modify cloudbr0 ipv4.method manual ipv4.addresses $MY_STRG_IP

# Attach Bond0 directly to Cloudbr0 (No VLAN interface)
nmcli connection modify bond0 master cloudbr0

# --- B. MANAGEMENT & PUBLIC NETWORK (bond1 -> cloudbr1/100) ---
# Logic: Trunk Port on Switch (Tagged) -> VLAN Interfaces -> Bridges
echo "--- Deploying Management & Public Network (MTU $MTU_STD) ---"

# Bond1 Master
nmcli connection add type bond ifname bond1 con-name bond1 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast" mtu $MTU_STD connection.autoconnect yes

# Bond1 Slaves
for slave in $MY_BOND1_SLAVES; do
    nmcli connection add type ethernet ifname $slave master bond1 con-name "bond1-slave-$slave" mtu $MTU_STD connection.autoconnect yes
done

# B1. Management (cloudbr1 - VLAN 41)
nmcli connection add type bridge ifname cloudbr1 con-name cloudbr1 bridge.stp no mtu $MTU_STD connection.autoconnect yes
nmcli connection modify cloudbr1 ipv4.method manual ipv4.addresses $MY_MGMT_IP ipv4.gateway $GATEWAY ipv4.dns "$DNS"
# VLAN Interface (bond1.41) attached to Bridge
nmcli connection add type vlan ifname bond1.$VLAN_MGMT dev bond1 id $VLAN_MGMT \
    master cloudbr1 slave-type bridge con-name "bond1.$VLAN_MGMT-bridge" mtu $MTU_STD connection.autoconnect yes

# B2. Public (cloudbr100 - VLAN 100)
nmcli connection add type bridge ifname cloudbr100 con-name cloudbr100 bridge.stp no mtu $MTU_STD connection.autoconnect yes
nmcli connection modify cloudbr100 ipv4.method disabled ipv6.method disabled
# VLAN Interface (bond1.100) attached to Bridge
nmcli connection add type vlan ifname bond1.$VLAN_PUBLIC dev bond1 id $VLAN_PUBLIC \
    master cloudbr100 slave-type bridge con-name "bond1.$VLAN_PUBLIC-bridge" mtu $MTU_STD connection.autoconnect yes

# --- C. CLOUDSTACK AGENT CONFIGURATION ---
echo "--- Updating CloudStack Agent Properties ---"
# Function to update property
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
    update_prop "public.network.device" "cloudbr100"
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
nmcli connection up cloudbr100

echo "--- Verifying Connectivity (Waiting 20s) ---"
sleep 20

if ping -c 3 -W 2 $GATEWAY; then
    echo "✅ SUCCESS: Network Deployed & Gateway Reachable."
    echo "------------------------------------------------"
    ip -br a | grep -E "cloudbr|bond"
    echo "------------------------------------------------"
    echo "Restarting CloudStack Agent..."
    systemctl restart cloudstack-agent
else
    rollback
fi
