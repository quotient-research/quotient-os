#!/usr/bin/env bash
# First boot of an installed QuotientOS: install the bundled
# quotient-server-tools package. Its postinst then runs the normal first-boot
# configuration (MicroK8s, manifests, Setup code), non-interactively because
# /etc/quotient/install.conf was written by the installer.
set -euo pipefail
MARK=/var/lib/quotient-os/.firstboot-done
LOG=/var/log/quotient-os-firstboot.log
exec >>"$LOG" 2>&1
echo "=== $(date -u +%FT%TZ) QuotientOS first boot"
[ -e "$MARK" ] && { echo "already done"; exit 0; }

DEB=$(ls /var/lib/quotient-os/quotient-server-tools_*.deb 2>/dev/null | sort -V | tail -1)
[ -n "$DEB" ] || { echo "no bundled package"; exit 1; }

# The seeded MicroK8s snap must be in place before postinst looks for it.
if ! snap list microk8s >/dev/null 2>&1; then
  for _ in $(seq 1 60); do snap list microk8s >/dev/null 2>&1 && break; sleep 5; done
fi
snap list microk8s || echo "warning: MicroK8s not seeded; configure will download it"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq "$DEB"
touch "$MARK"
echo "=== done"
