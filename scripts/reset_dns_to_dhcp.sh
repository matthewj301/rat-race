#!/bin/bash
# reset_dns_to_dhcp.sh — Restore default DHCP-based DNS handling

set -e

echo "Cleaning resolvconf config files..."

for file in head base original; do
    path="/etc/resolvconf/resolv.conf.d/$file"
    if [[ -f "$path" ]]; then
        sudo truncate -s 0 "$path"
        echo "Cleared $path"
    fi
done

echo "Removing any immutable flags (if applied)..."
sudo chattr -i /etc/resolv.conf 2>/dev/null || true

echo "Deleting /etc/resolv.conf and regenerating from DHCP..."
sudo rm -f /etc/resolv.conf
sudo resolvconf -u
sudo systemctl restart dhcpcd

echo "Current /etc/resolv.conf:"
cat /etc/resolv.conf

echo "Restored DHCP-managed DNS."

