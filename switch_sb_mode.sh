#!/bin/bash

# Configuration paths
SB_CONFIG="/etc/s-box/sb.json"
BACKUP_CONFIG="/etc/s-box/sb.json.bak"
SERVICE_NAME="sing-box" # Verify your service name, sometimes it might be 'sing-box.service'

# Check for root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root"
  exit 1
fi

# Check and install jq if missing
if ! command -v jq &> /dev/null; then
    echo "jq is required but not installed. Installing..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y jq
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y jq
    else
        echo "OS not supported for auto-install. Please install 'jq' manually."
        exit 1
    fi
fi

echo "==========================================="
echo " Sing-box Outbound Strategy Switcher"
echo "==========================================="
echo "1. Mode: Native IPv4 (Use physical network card)"
echo "   - Removes preference for IPv6"
echo "   - Removes forced IPv6 via WARP"
echo ""
echo "2. Mode: IPv6 Preferred (Use WARP IPv6 if available)"
echo "   - Adds preference for IPv6 resolution"
echo "   - Routes all IPv6 traffic via WARP"
echo "==========================================="
read -p "Enter your choice [1 or 2]: " choice

# Function to backup config
backup_config() {
    echo "Backing up configuration to $BACKUP_CONFIG..."
    cp "$SB_CONFIG" "$BACKUP_CONFIG"
}

case "$choice" in
    1)
        echo "Switching to Native IPv4 Mode..."
        backup_config
        
        # Logic: Delete the specific IPv6 rules
        # 1. Delete global prefer_ipv6 strategy (checking domain_suffix is null to avoid deleting specific domain rules)
        # 2. Delete the specific warp-out rule for ::/0
        tmp=$(mktemp)
        jq 'del(.route.rules[] | select(.strategy == "prefer_ipv6" and .domain_suffix == null)) | 
            del(.route.rules[] | select(.outbound == "warp-out" and (.ip_cidr | contains(["::/0"]))))' \
            "$SB_CONFIG" > "$tmp" && mv "$tmp" "$SB_CONFIG"
        
        echo "Modifications applied."
        ;;
    2)
        echo "Switching to IPv6 Preferred Mode..."
        backup_config
        
        tmp=$(mktemp)
        # Step 1: Clean up existing rules to avoid duplicates (same as Mode 1)
        jq 'del(.route.rules[] | select(.strategy == "prefer_ipv6" and .domain_suffix == null)) | 
            del(.route.rules[] | select(.outbound == "warp-out" and (.ip_cidr | contains(["::/0"]))))' \
            "$SB_CONFIG" > "$tmp"
            
        # Step 2: Insert new rules after the first rule (assuming index 0 is "sniff" or similar base rule)
        # We inject: 1. Global IPv6 preference 2. Route ::/0 to warp-out
        jq '.route.rules |= [.[0]] + [
            {
                "action": "resolve",
                "strategy": "prefer_ipv6"
            },
            {
                "ip_cidr": ["::/0"],
                "outbound": "warp-out"
            }
        ] + .[1:]' "$tmp" > "$SB_CONFIG"
        rm -f "$tmp"
        
        echo "Modifications applied."
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

# Restart Service
echo "Restarting $SERVICE_NAME..."
if systemctl restart "$SERVICE_NAME"; then
    echo "Success! Service restarted."
    systemctl status "$SERVICE_NAME" --no-pager | grep "Active:"
else
    echo "Error: Failed to restart service. Please check configuration."
    echo "Restoring backup..."
    cp "$BACKUP_CONFIG" "$SB_CONFIG"
fi
