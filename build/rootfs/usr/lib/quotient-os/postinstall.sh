#!/usr/bin/env bash
# The Quotient-specific part of an install. Runs inside the installed system
# (chroot) at the end of both the Calamares and the unattended installs.
# Commodity steps (partition, unpack, users, bootloader) are done by whichever
# installer called us; this is everything the Mainframe needs on top.
set -euo pipefail

# 1. How Quotient fits on this computer. The computer is a Mainframe and
#    nothing else, so these are decided here, not asked.
mkdir -p /etc/quotient
if [ ! -s /etc/quotient/install.conf ]; then
  cat > /etc/quotient/install.conf <<'EOF'
# /etc/quotient/install.conf — written by the QuotientOS installer.
http_port=80
samba=off
firewall=auto
auto_update=on
desktop_shortcut=off
EOF
fi

# 1b. The seeded MicroK8s exists for Quotient. Without this marker the package
#     treats it as the owner's own cluster and refuses to touch it (harness N).
mkdir -p /var/lib/quotient/installed
[ -s /var/lib/quotient/installed/microk8s ] || date -Iseconds > /var/lib/quotient/installed/microk8s

# 2. Firewall on, before the package runs, so firewall=auto adds Quotient's ports.
if command -v ufw >/dev/null; then
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || true
  sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
fi

# 3. The Mainframe's name is advertised on the LAN as-is.
HN=$(cat /etc/hostname)
sed -i "s/^#\?host-name=.*/host-name=$HN/" /etc/avahi/avahi-daemon.conf 2>/dev/null || true

# 4. First boot and the status console.
systemctl enable quotient-os-firstboot.service quotient-console.service NetworkManager ssh avahi-daemon >/dev/null 2>&1 || true
systemctl disable getty@tty1.service >/dev/null 2>&1 || true

# 5. Ubuntu security updates on their own; Quotient updates through its channel.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# 6. Nothing live-only survives. The base never had these, but a Calamares
#    unpack of a merged tree would.
rm -f /usr/lib/systemd/system/quotient-installer.service
systemctl disable quotient-installer.service >/dev/null 2>&1 || true
echo "postinstall done for $HN"
