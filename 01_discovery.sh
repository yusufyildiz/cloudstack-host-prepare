#!/bin/bash
# ==============================================================================
# SCRIPT: 01_discovery.sh
# DESCRIPTION: Interactive Network Discovery & Config Generator
# OUTPUT: server.conf
# ==============================================================================

OUTPUT_FILE="server.conf"
HOST_NAME=$(hostname)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
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

# Helper Function: Ask for tagged/untagged mode
ask_mode() {
    local network_type=$1
    local mode=""
    while true; do
        echo -e "${CYAN}Is $network_type interface TAGGED (trunk) or UNTAGGED (access)?${NC}" >&2
        read -p "Enter [t]agged or [u]ntagged: " mode_input
        case $mode_input in
            [Tt]|tagged|TAGGED|trunk|TRUNK)
                mode="tagged"
                break
                ;;
            [Uu]|untagged|UNTAGGED|access|ACCESS)
                mode="untagged"
                break
                ;;
            *)
                echo -e "${RED}   ❌ Invalid input. Please enter 't' for tagged or 'u' for untagged.${NC}" >&2
                ;;
        esac
    done
    echo "$mode"
}

# --- 2. USER INPUT (Storage) ---
echo -e "${YELLOW}=== STORAGE NETWORK CONFIGURATION ===${NC}"
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

# Storage Mode Selection
STRG_MODE=$(ask_mode "STORAGE")
echo -e "   ✅ Mode: $STRG_MODE"

# Storage VLAN (if tagged)
if [ "$STRG_MODE" == "tagged" ]; then
    read -p "Enter STORAGE VLAN ID: " VLAN_STORAGE
    echo -e "   ✅ VLAN: $VLAN_STORAGE"
else
    VLAN_STORAGE=""
fi

# --- 3. USER INPUT (Management) ---
echo -e "\n${YELLOW}=== MANAGEMENT/PUBLIC NETWORK CONFIGURATION ===${NC}"
while true; do
    echo -e "${YELLOW}Which interface carries MANAGEMENT/PUBLIC traffic?${NC}"
    read -p "Interface Name (e.g., bond1, ens1f0): " INPUT_MGMT_IF
    if ip link show "$INPUT_MGMT_IF" > /dev/null 2>&1; then
        echo -e "   ✅ Selected: $INPUT_MGMT_IF"
        break
    else
        echo -e "${RED}   ❌ Error: Interface '$INPUT_MGMT_IF' not found.${NC}"
    fi
done

# Management Mode Selection
MGMT_MODE=$(ask_mode "MANAGEMENT")
echo -e "   ✅ Mode: $MGMT_MODE"

# Management VLANs (if tagged)
if [ "$MGMT_MODE" == "tagged" ]; then
    read -p "Enter MANAGEMENT VLAN ID (e.g., 41): " VLAN_MGMT
    echo -e "   ✅ Management VLAN: $VLAN_MGMT"
    read -p "Enter PUBLIC VLAN ID (e.g., 100): " VLAN_PUBLIC
    echo -e "   ✅ Public VLAN: $VLAN_PUBLIC"
else
    VLAN_MGMT=""
    VLAN_PUBLIC=""
fi

echo -e "\n${YELLOW}--- Analyzing Configuration... ---${NC}"

# 4. Extract Physical Ports (Slaves)
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

# 5. Detect IPs (Best Effort)
# Try to find IPs based on common patterns or existing config
if [ "$STRG_MODE" == "tagged" ] && [ -n "$VLAN_STORAGE" ]; then
    RAW_STRG_IP=$(ip -o addr show | grep -E "\.${VLAN_STORAGE}\." | awk '{print $4}' | head -1)
else
    RAW_STRG_IP=$(ip -o addr show "$INPUT_STRG_IF" 2>/dev/null | grep "inet " | awk '{print $4}' | head -1)
fi

if [ "$MGMT_MODE" == "tagged" ] && [ -n "$VLAN_MGMT" ]; then
    RAW_MGMT_IP=$(ip -o addr show | grep -E "\.${VLAN_MGMT}\." | awk '{print $4}' | head -1)
else
    RAW_MGMT_IP=$(ip -o addr show "$INPUT_MGMT_IF" 2>/dev/null | grep "inet " | awk '{print $4}' | head -1)
fi

MY_STRG_IP=${RAW_STRG_IP:-"MANUAL_INPUT_REQUIRED"}
MY_MGMT_IP=${RAW_MGMT_IP:-"MANUAL_INPUT_REQUIRED"}

# 6. Ask for Gateway and DNS
echo -e "\n${YELLOW}=== NETWORK SETTINGS ===${NC}"
read -p "Enter Gateway IP [10.1.41.1]: " INPUT_GATEWAY
GATEWAY=${INPUT_GATEWAY:-"10.1.41.1"}

read -p "Enter DNS Server [8.8.8.8]: " INPUT_DNS
DNS=${INPUT_DNS:-"8.8.8.8"}

# 7. Generate Config File
cat <<EOF > $OUTPUT_FILE
# ==========================================
# SERVER CONFIGURATION: $HOST_NAME
# Source: $INPUT_STRG_IF (Storage) / $INPUT_MGMT_IF (Mgmt)
# Generated: $(date)
# ==========================================

# --- HOST INFORMATION ---
MY_HOSTNAME="$HOST_NAME"
MY_MGMT_IP="$MY_MGMT_IP"
MY_STRG_IP="$MY_STRG_IP"

# --- PHYSICAL PORTS ---
# Storage Network (Target: bond0, MTU 9000)
MY_BOND0_SLAVES="$STRG_SLAVES"

# Management/Public Network (Target: bond1, MTU 1500)
MY_BOND1_SLAVES="$MGMT_SLAVES"

# --- SWITCH PORT MODE ---
# Options: "tagged" (trunk) or "untagged" (access)
STRG_MODE="$STRG_MODE"
MGMT_MODE="$MGMT_MODE"

# --- VLAN CONFIGURATION ---
# Leave empty if untagged/access mode
VLAN_STORAGE="$VLAN_STORAGE"
VLAN_MGMT="$VLAN_MGMT"
VLAN_PUBLIC="$VLAN_PUBLIC"

# --- GLOBAL SETTINGS ---
GATEWAY="$GATEWAY"
DNS="$DNS"

# --- MTU CONFIGURATION ---
MTU_STD="1500"
MTU_JUMBO="9000"
EOF

echo -e "\n${GREEN}✅ SUCCESS: Configuration file '$OUTPUT_FILE' created.${NC}"
echo "---------------------------------------------------------"
echo "Storage:    $MY_STRG_IP (Mode: $STRG_MODE, VLAN: ${VLAN_STORAGE:-N/A})"
echo "Management: $MY_MGMT_IP (Mode: $MGMT_MODE, VLAN: ${VLAN_MGMT:-N/A})"
echo "Public:     VLAN ${VLAN_PUBLIC:-N/A}"
echo "Ports:      Storage=[$STRG_SLAVES] | Mgmt=[$MGMT_SLAVES]"
echo "Gateway:    $GATEWAY | DNS: $DNS"
echo "---------------------------------------------------------"
echo -e "${YELLOW}👉 ACTION: Please open '$OUTPUT_FILE' and verify settings before deploying.${NC}"
