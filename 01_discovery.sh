#!/bin/bash
# ==============================================================================
# SCRIPT: 01_discover.sh
# DESCRIPTION: Interactive Network Discovery & Config Generator
# OUTPUT: server.conf
# ==============================================================================

OUTPUT_FILE="server.conf"
HOST_NAME=$(hostname)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   INTERACTIVE NETWORK DISCOVERY - $HOST_NAME   ${NC}"
echo -e "${GREEN}=================================================${NC}"

# 1. List Available Interfaces
echo -e "\n${YELLOW}--- Available Network Interfaces ---${NC}"
ip -o link show | awk -F': ' '{print $2}' | grep -vE "^(lo|vnet|virbr|vlan|docker)" | column
echo ""

# Helper Function: Find slaves of a bond
get_slaves() {
    local iface=$1
    if [ -f "/sys/class/net/$iface/bonding/slaves" ]; then
        cat "/sys/class/net/$iface/bonding/slaves" | tr ' ' '\n' | sort | xargs
    else
        echo "MANUAL_INPUT_REQUIRED"
    fi
}

# --- 2. USER INPUT (Storage) ---
while true; do
    echo -e "${YELLOW}Which interface carries STORAGE traffic (Linstor/DRBD)?${NC}"
    read -p "Interface Name (e.g., bond0, ens2f0): " INPUT_STRG_IF
    if ip link show "$INPUT_STRG_IF" > /dev/null 2>&1; then
        echo -e "   ✅ Selected: $INPUT_STRG_IF"
        break
    else
        echo -e "${RED}   ❌ Error: Interface '$INPUT_STRG_IF' not found.${NC}"
    fi
done

# --- 3. USER INPUT (Management) ---
while true; do
    echo -e "\n${YELLOW}Which interface carries MANAGEMENT/PUBLIC traffic?${NC}"
    read -p "Interface Name (e.g., bond1, ens1f0): " INPUT_MGMT_IF
    if ip link show "$INPUT_MGMT_IF" > /dev/null 2>&1; then
        echo -e "   ✅ Selected: $INPUT_MGMT_IF"
        break
    else
        echo -e "${RED}   ❌ Error: Interface '$INPUT_MGMT_IF' not found.${NC}"
    fi
done

echo -e "\n${YELLOW}--- Analyzing Configuration... ---${NC}"

# 4. Extract Physical Ports (Slaves)
# If user selected a bond, get slaves. If physical, use it directly.
if [ -f "/sys/class/net/$INPUT_STRG_IF/bonding/slaves" ]; then
    STRG_SLAVES=$(get_slaves "$INPUT_STRG_IF")
else
    STRG_SLAVES="$INPUT_STRG_IF"
fi

if [ -f "/sys/class/net/$INPUT_MGMT_IF/bonding/slaves" ]; then
    MGMT_SLAVES=$(get_slaves "$INPUT_MGMT_IF")
else
    MGMT_SLAVES="$INPUT_MGMT_IF"
fi

# 5. Detect IPs (Best Effort based on subnets)
# Adjust grep patterns if your subnets differ significantly
RAW_STRG_IP=$(ip -o addr show | grep "10.1.40." | awk '{print $4}' | head -1)
RAW_MGMT_IP=$(ip -o addr show | grep "10.1.41." | awk '{print $4}' | head -1)

MY_STRG_IP=${RAW_STRG_IP:-"MANUAL_INPUT_REQUIRED"}
MY_MGMT_IP=${RAW_MGMT_IP:-"MANUAL_INPUT_REQUIRED"}

# 6. Generate Config File
cat <<EOF > $OUTPUT_FILE
# ==========================================
# SERVER CONFIGURATION: $HOST_NAME
# Source: $INPUT_STRG_IF (Storage) / $INPUT_MGMT_IF (Mgmt)
# Generated: $(date)
# ==========================================

# --- HOST INFORMATION ---
MY_HOSTNAME="$HOST_NAME"
MY_MGMT_IP="$MY_MGMT_IP"      # Management IP (VLAN 41)
MY_STRG_IP="$MY_STRG_IP"      # Storage IP (VLAN 40)

# --- PHYSICAL PORTS ---
# Storage Network (Target: bond0, MTU 9000)
MY_BOND0_SLAVES="$STRG_SLAVES"

# Management/Public Network (Target: bond1, MTU 1500)
MY_BOND1_SLAVES="$MGMT_SLAVES"

# --- GLOBAL SETTINGS ---
GATEWAY="10.1.41.1"
DNS="8.8.8.8"

# --- VLAN CONFIGURATION ---
VLAN_MGMT="41"
VLAN_PUBLIC="100"
VLAN_STORAGE="40"

# --- MTU CONFIGURATION ---
MTU_STD="1500"
MTU_JUMBO="9000"
EOF

echo -e "${GREEN}✅ SUCCESS: Configuration file '$OUTPUT_FILE' created.${NC}"
echo "---------------------------------------------------------"
echo "Storage IP: $MY_STRG_IP"
echo "Mgmt IP:    $MY_MGMT_IP"
echo "Ports:      Storage=[$STRG_SLAVES] | Mgmt=[$MGMT_SLAVES]"
echo "---------------------------------------------------------"
echo "👉 ACTION: Please open '$OUTPUT_FILE' and verify IP addresses before deploying."
