#!/usr/bin/env bash
# =============================================================================
# Pi Installer Setup Script
# Run ONCE on the Raspberry Pi to configure it as the plug-and-play installer.
#
# What this does:
#   1. Sets a static IP on the ethernet port (eth0) → 192.168.42.1
#   2. Installs dnsmasq (DHCP server — gives target machine an IP automatically)
#   3. Installs avahi-daemon (mDNS — makes Pi reachable as multirat-pi.local)
#   4. Creates a systemd service so the web server starts on every boot
#   5. Starts the web server immediately
#
# Usage (on the Pi, once SSH'd in):
#   sudo bash setup_pi.sh
# =============================================================================
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")" && pwd)"
ETH_IFACE="eth0"
PI_IP="192.168.42.1"
DHCP_RANGE_START="192.168.42.100"
DHCP_RANGE_END="192.168.42.200"
HOSTNAME="multirat-pi"

echo "================================================"
echo "  Multi-RAT Pi Installer Setup"
echo "================================================"
echo ""

# ── 1. Set hostname ───────────────────────────────────────────────────────────
echo "[1/5] Setting hostname to $HOSTNAME…"
hostnamectl set-hostname "$HOSTNAME"
grep -qF "127.0.1.1 $HOSTNAME" /etc/hosts \
    || echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
echo "  ✓ Hostname set"

# ── 2. Configure static IP on ethernet ───────────────────────────────────────
echo "[2/5] Configuring static IP $PI_IP on $ETH_IFACE…"

# Use NetworkManager if present (Ubuntu Desktop), else netplan (Ubuntu Server)
if command -v nmcli &>/dev/null; then
    nmcli con mod "Wired connection 1" \
        ipv4.addresses "$PI_IP/24" \
        ipv4.method manual 2>/dev/null \
    || nmcli con add type ethernet ifname "$ETH_IFACE" \
        con-name "multirat-eth" \
        ipv4.addresses "$PI_IP/24" \
        ipv4.method manual
    nmcli con up "multirat-eth" 2>/dev/null || nmcli con up "Wired connection 1" 2>/dev/null || true
else
    # Netplan (Ubuntu Server)
    cat > /etc/netplan/99-multirat-eth.yaml <<EOF
network:
  version: 2
  ethernets:
    $ETH_IFACE:
      addresses:
        - $PI_IP/24
      dhcp4: false
EOF
    netplan apply
fi
echo "  ✓ Static IP configured: $PI_IP"

# ── 3. Install and configure dnsmasq (DHCP) ───────────────────────────────────
echo "[3/5] Installing dnsmasq…"
apt-get install -y -qq dnsmasq

# Back up original config
[[ -f /etc/dnsmasq.conf.orig ]] || cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

cat > /etc/dnsmasq.d/multirat.conf <<EOF
# Multi-RAT installer DHCP for ethernet
interface=$ETH_IFACE
bind-interfaces
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,12h
dhcp-option=option:router,$PI_IP
# Redirect multirat-pi.local to Pi IP (fallback if avahi not working)
address=/multirat-pi.local/$PI_IP
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq
echo "  ✓ DHCP server running (gives target machine IP automatically)"

# ── 4. Install avahi-daemon (mDNS — .local hostname) ─────────────────────────
echo "[4/5] Installing avahi-daemon (mDNS)…"
apt-get install -y -qq avahi-daemon avahi-utils
systemctl enable avahi-daemon
systemctl start  avahi-daemon
echo "  ✓ mDNS running — Pi reachable as $HOSTNAME.local"

# ── 5. Create systemd service for the web server ──────────────────────────────
echo "[5/5] Creating web server systemd service…"
cat > /etc/systemd/system/multirat-installer.service <<EOF
[Unit]
Description=Multi-RAT Pi Installer Web Server
After=network.target avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALLER_DIR/server.py
WorkingDirectory=$INSTALLER_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable multirat-installer
systemctl restart multirat-installer
echo "  ✓ Web server started and enabled on boot"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Setup complete!"
echo ""
echo "  1. Plug an ethernet cable from the Pi into"
echo "     the target machine."
echo ""
echo "  2. On the target machine, open a browser and"
echo "     go to:  http://multirat-pi.local"
echo ""
echo "  3. Follow the on-screen instructions."
echo "================================================"
echo ""
