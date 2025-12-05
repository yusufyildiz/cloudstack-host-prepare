#!/bin/bash
# ==============================================================================
# SCRIPT: 08_validate.sh
# DESCRIPTION: Post-deployment network validation and testing
# ==============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="server.conf"
PASS=0
FAIL=0
WARN=0

echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   NETWORK VALIDATION - $(hostname)              ${NC}"
echo -e "${GREEN}=================================================${NC}"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${CYAN}Configuration loaded from $CONFIG_FILE${NC}\n"
else
    echo -e "${YELLOW}Warning: $CONFIG_FILE not found, using defaults${NC}\n"
fi

# Test function
run_test() {
    local name=$1
    local result=$2
    local details=${3:-""}

    if [ "$result" -eq 0 ]; then
        echo -e "[${GREEN}PASS${NC}] $name"
        [ -n "$details" ] && echo -e "       $details"
        ((PASS++))
    else
        echo -e "[${RED}FAIL${NC}] $name"
        [ -n "$details" ] && echo -e "       $details"
        ((FAIL++))
    fi
}

run_warn() {
    local name=$1
    local details=${2:-""}
    echo -e "[${YELLOW}WARN${NC}] $name"
    [ -n "$details" ] && echo -e "       $details"
    ((WARN++))
}

# ==============================================================================
# 1. BOND STATUS TESTS
# ==============================================================================
echo -e "${YELLOW}=== BOND STATUS ===${NC}"

for bond in bond0 bond1; do
    if [ -f "/proc/net/bonding/$bond" ]; then
        mode=$(grep "Bonding Mode:" "/proc/net/bonding/$bond" | cut -d: -f2 | xargs)
        slaves_up=$(grep -c "MII Status: up" "/proc/net/bonding/$bond" 2>/dev/null || echo 0)
        slaves_total=$(grep -c "Slave Interface:" "/proc/net/bonding/$bond" 2>/dev/null || echo 0)

        if [ "$slaves_up" -eq "$slaves_total" ] && [ "$slaves_total" -gt 0 ]; then
            run_test "$bond status" 0 "Mode: $mode, Slaves: $slaves_up/$slaves_total UP"
        elif [ "$slaves_up" -gt 0 ]; then
            run_warn "$bond degraded" "Mode: $mode, Slaves: $slaves_up/$slaves_total UP"
        else
            run_test "$bond status" 1 "No slaves UP"
        fi
    else
        run_test "$bond exists" 1 "Bond not found"
    fi
done

# ==============================================================================
# 2. BRIDGE STATUS TESTS
# ==============================================================================
echo -e "\n${YELLOW}=== BRIDGE STATUS ===${NC}"

for br in cloudbr0 cloudbr1 cloudbr100; do
    if ip link show "$br" &>/dev/null; then
        state=$(ip -br link show "$br" | awk '{print $2}')
        if [ "$state" == "UP" ]; then
            # Check for attached interfaces
            attached=$(bridge link show | grep "master $br" | wc -l)
            run_test "$br status" 0 "State: UP, Attached interfaces: $attached"
        else
            run_test "$br status" 1 "State: $state"
        fi
    else
        if [ "$br" == "cloudbr100" ]; then
            # cloudbr100 is optional (only for tagged mode)
            run_warn "$br not found" "Optional bridge (tagged mode only)"
        else
            run_test "$br exists" 1 "Bridge not found"
        fi
    fi
done

# ==============================================================================
# 3. IP ADDRESS TESTS
# ==============================================================================
echo -e "\n${YELLOW}=== IP ADDRESSES ===${NC}"

# Storage IP
if ip link show cloudbr0 &>/dev/null; then
    strg_ip=$(ip -4 addr show cloudbr0 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    if [ -n "$strg_ip" ]; then
        run_test "cloudbr0 IP" 0 "$strg_ip"
    else
        run_test "cloudbr0 IP" 1 "No IP assigned"
    fi
fi

# Management IP
if ip link show cloudbr1 &>/dev/null; then
    mgmt_ip=$(ip -4 addr show cloudbr1 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    if [ -n "$mgmt_ip" ]; then
        run_test "cloudbr1 IP" 0 "$mgmt_ip"
    else
        run_test "cloudbr1 IP" 1 "No IP assigned"
    fi
fi

# ==============================================================================
# 4. CONNECTIVITY TESTS
# ==============================================================================
echo -e "\n${YELLOW}=== CONNECTIVITY ===${NC}"

# Gateway test
gateway=$(ip route | grep default | awk '{print $3}' | head -1)
if [ -n "$gateway" ]; then
    if ping -c 2 -W 2 "$gateway" &>/dev/null; then
        run_test "Gateway reachable" 0 "$gateway"
    else
        run_test "Gateway reachable" 1 "$gateway unreachable"
    fi
else
    run_test "Default gateway" 1 "No default gateway configured"
fi

# DNS test
dns_server=${DNS:-"8.8.8.8"}
if ping -c 2 -W 2 "$dns_server" &>/dev/null; then
    run_test "DNS reachable" 0 "$dns_server"
else
    run_warn "DNS unreachable" "$dns_server"
fi

# ==============================================================================
# 5. MTU TESTS
# ==============================================================================
echo -e "\n${YELLOW}=== MTU CONFIGURATION ===${NC}"

# Storage MTU (should be 9000)
if ip link show bond0 &>/dev/null; then
    bond0_mtu=$(ip link show bond0 | grep -oP 'mtu \K\d+')
    if [ "$bond0_mtu" -eq 9000 ]; then
        run_test "bond0 MTU" 0 "$bond0_mtu (Jumbo frames enabled)"
    else
        run_warn "bond0 MTU" "Expected 9000, got $bond0_mtu"
    fi
fi

if ip link show cloudbr0 &>/dev/null; then
    br0_mtu=$(ip link show cloudbr0 | grep -oP 'mtu \K\d+')
    if [ "$br0_mtu" -eq 9000 ]; then
        run_test "cloudbr0 MTU" 0 "$br0_mtu"
    else
        run_warn "cloudbr0 MTU" "Expected 9000, got $br0_mtu"
    fi
fi

# Management MTU (should be 1500)
if ip link show bond1 &>/dev/null; then
    bond1_mtu=$(ip link show bond1 | grep -oP 'mtu \K\d+')
    if [ "$bond1_mtu" -eq 1500 ]; then
        run_test "bond1 MTU" 0 "$bond1_mtu"
    else
        run_warn "bond1 MTU" "Expected 1500, got $bond1_mtu"
    fi
fi

# ==============================================================================
# 6. VLAN TESTS (if tagged mode)
# ==============================================================================
echo -e "\n${YELLOW}=== VLAN INTERFACES ===${NC}"

STRG_MODE=${STRG_MODE:-"untagged"}
MGMT_MODE=${MGMT_MODE:-"tagged"}

if [ "$STRG_MODE" == "tagged" ] && [ -n "${VLAN_STORAGE:-}" ]; then
    vlan_if="bond0.$VLAN_STORAGE"
    if ip link show "$vlan_if" &>/dev/null; then
        run_test "Storage VLAN ($vlan_if)" 0 "Exists"
    else
        run_test "Storage VLAN ($vlan_if)" 1 "Not found"
    fi
else
    echo -e "${CYAN}Storage: Untagged mode (no VLAN interface)${NC}"
fi

if [ "$MGMT_MODE" == "tagged" ] && [ -n "${VLAN_MGMT:-}" ]; then
    vlan_if="bond1.$VLAN_MGMT"
    if ip link show "$vlan_if" &>/dev/null; then
        run_test "Management VLAN ($vlan_if)" 0 "Exists"
    else
        run_test "Management VLAN ($vlan_if)" 1 "Not found"
    fi

    if [ -n "${VLAN_PUBLIC:-}" ]; then
        vlan_if="bond1.$VLAN_PUBLIC"
        if ip link show "$vlan_if" &>/dev/null; then
            run_test "Public VLAN ($vlan_if)" 0 "Exists"
        else
            run_test "Public VLAN ($vlan_if)" 1 "Not found"
        fi
    fi
else
    echo -e "${CYAN}Management: Untagged mode (no VLAN interface)${NC}"
fi

# ==============================================================================
# 7. BOND FAILOVER TEST (Optional)
# ==============================================================================
echo -e "\n${YELLOW}=== BOND FAILOVER CAPABILITY ===${NC}"

for bond in bond0 bond1; do
    if [ -f "/proc/net/bonding/$bond" ]; then
        slaves=$(grep "Slave Interface:" "/proc/net/bonding/$bond" | awk '{print $3}')
        slave_count=$(echo "$slaves" | wc -w)

        if [ "$slave_count" -ge 2 ]; then
            run_test "$bond redundancy" 0 "$slave_count slaves configured (failover capable)"
        else
            run_warn "$bond redundancy" "Only $slave_count slave (no failover)"
        fi
    fi
done

# ==============================================================================
# 8. JUMBO FRAME PATH TEST
# ==============================================================================
echo -e "\n${YELLOW}=== JUMBO FRAME PATH TEST ===${NC}"

# Get storage network peer (if available)
strg_ip=$(ip -4 addr show cloudbr0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
if [ -n "$strg_ip" ]; then
    # Try to find another host on the same subnet
    subnet=$(echo "$strg_ip" | cut -d. -f1-3)

    echo -e "${CYAN}Testing MTU 9000 path on storage network...${NC}"
    echo -e "${CYAN}To test jumbo frames between hosts, run:${NC}"
    echo -e "   ping -M do -s 8972 <other-host-storage-ip>"
    echo -e "${CYAN}If this fails, check switch MTU configuration.${NC}"
else
    run_warn "Jumbo frame test" "No storage IP found"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN}   VALIDATION SUMMARY                            ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo -e "   ${GREEN}PASSED:${NC}  $PASS"
echo -e "   ${YELLOW}WARNINGS:${NC} $WARN"
echo -e "   ${RED}FAILED:${NC}  $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}❌ Validation completed with failures. Please review and fix.${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Validation completed with warnings.${NC}"
    exit 0
else
    echo -e "${GREEN}✅ All tests passed successfully!${NC}"
    exit 0
fi
