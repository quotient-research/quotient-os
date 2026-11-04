#!/usr/bin/env bash
# QuotientOS install harness. Boots an ISO in a throwaway LXD VM, installs
# unattended, reboots into the disk and checks that the Mainframe comes up.
# Runs on the LXD host (ep-ai). Mirrors quotient-server's install harness.
#
#   ./os-harness.sh run --iso FILE [--scenarios O1,O3] [--keep] [--logs DIR]
#   ./os-harness.sh clean
#
# Scenarios
#   O1  unattended install, Secure Boot off, reboot, healthy
#   O3  the same with Secure Boot on
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CMD=${1:-}; shift || true
ISO=""; SCENARIOS=O1; KEEP=0; LOGS="$HERE/logs/$(date -u +%Y%m%dT%H%M%SZ)"
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --scenarios) SCENARIOS="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --logs) LOGS="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$LOGS"
LOGS=$(readlink -f "$LOGS")
[ -z "$ISO" ] || ISO=$(readlink -f "$ISO")
RUNLOG=$LOGS/run.log
exec > >(tee -a "$RUNLOG") 2>&1
log() { printf '\033[1;34m[%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { printf '\033[1;32mPASS %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL %s\033[0m\n' "$*"; FAILED=1; }
FAILED=0

if [ "$CMD" = clean ]; then
  for v in $(lxc list --format csv -c n | grep '^qos-' || true); do lxc delete -f "$v"; done
  exit 0
fi
[ "$CMD" = run ] || { sed -n 2,14p "$0"; exit 2; }
[ -r "$ISO" ] || { echo "no ISO at $ISO" >&2; exit 2; }
# One VM at a time on this host: our own lock, and the quotient-server install harness.
exec 9>/tmp/quotient-os-harness.lock
flock -n 9 || { echo "another QuotientOS harness run is in progress" >&2; exit 3; }
if pgrep -f 'install-harness/harness.sh run' >/dev/null; then echo "the quotient-server install harness is running" >&2; exit 3; fi

NAME=lakehouse; USER_=owner; PASS=$(openssl rand -hex 8)
SSHKEY=$LOGS/id_ed25519; ssh-keygen -q -t ed25519 -N '' -f "$SSHKEY" </dev/null
SSH_OPTS=(-i "$SSHKEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

# Remaster the ISO with the answers on the medium (GRUB picks the unattended entry).
ANS=$LOGS/answers.conf
cat > "$ANS" <<EOF
disk=/dev/sda
name=$NAME
user=$USER_
password=$PASS
ssh_key=$(cat "$SSHKEY.pub")
timezone=America/New_York
poweroff=1
EOF
HISO=$LOGS/harness.iso
log "Remastering $ISO with answers → $HISO"
sudo "$HERE/../build/build-iso.sh" --remaster --answers "$ANS" --iso-out "$HISO" >"$LOGS/remaster.log" 2>&1 || { cat "$LOGS/remaster.log"; exit 1; }

vm_ip() {
  lxc list "$1" --format csv -c 4 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 ||
  lxc network list-leases lxdbr0 --format csv 2>/dev/null | awk -F, -v n="$NAME" 'tolower($1)==n {print $3; exit}'
}
ssh_vm() { ssh "${SSH_OPTS[@]}" "$USER_@$IP" "$@"; }
sudo_vm() { ssh "${SSH_OPTS[@]}" "$USER_@$IP" "echo '$PASS' | sudo -S -p '' $*"; }
wait_for() { # wait_for SECONDS DESCRIPTION CMD...
  local t=$1 d=$2; shift 2
  local start; start=$(date +%s)
  while ! "$@" >/dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge "$t" ]; then echo "timeout waiting for $d"; return 1; fi
    sleep 10
  done
  log "$d after $(( $(date +%s) - start ))s"
}

scenario() {
  local id=$1 sb=$2 vm
  vm=qos-$(echo "$id" | tr 'A-Z' 'a-z')
  log "=== $id (secureboot=$sb) on $vm"
  lxc delete -f "$vm" >/dev/null 2>&1 || true
  lxc init "$vm" --empty --vm -c limits.cpu=3 -c limits.memory=4GiB -c "security.secureboot=$sb" -d root,size=30GiB >/dev/null
  lxc config device add "$vm" iso disk source="$HISO" boot.priority=10 >/dev/null
  # Start with the serial console captured to a log (a VM's console is only
  # readable live), detached so the harness can keep polling.
  start_with_console() { # start_with_console VM LOGFILE
    (setsid nohup script -q -c "lxc start $1 --console" "$2" >/dev/null 2>&1 </dev/null &)
    sleep 3
  }
  start_with_console "$vm" "$LOGS/$id-install-console.log"
  log "Installing from the ISO (unattended)"
  sleep 60   # the VM must be seen RUNNING before STOPPED means "finished"
  if ! wait_for 1500 "install finished (VM powered off)" sh -c "lxc info $vm | grep -q 'Status: STOPPED'"; then
    fail "$id install did not finish"; return
  fi
  lxc config device remove "$vm" iso >/dev/null
  start_with_console "$vm" "$LOGS/$id-boot-console.log"
  log "Booting the installed disk"
  IP=""
  if ! wait_for 300 "DHCP lease for $NAME" sh -c "ip=\$(lxc network list-leases lxdbr0 --format csv | awk -F, -v n=$NAME '\$1==n{print \$3}' | head -1); [ -n \"\$ip\" ]"; then
    fail "$id no DHCP lease"; return
  fi
  IP=$(lxc network list-leases lxdbr0 --format csv | awk -F, -v n="$NAME" '$1==n{print $3}' | head -1)
  log "VM address $IP"
  wait_for 300 "SSH" ssh_vm true || { fail "$id no SSH"; return; }

  [ "$(ssh_vm hostname)" = "$NAME" ] && pass "$id hostname $NAME" || fail "$id hostname is $(ssh_vm hostname)"
  if [ "$sb" = true ]; then
    sudo_vm "od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" | grep -q ' 1$' \
      && pass "$id booted with Secure Boot on" || fail "$id Secure Boot not reported on"
  fi
  ssh_vm 'test -f /var/lib/snapd/seed/seed.yaml' && pass "$id snap seed present" || fail "$id no snap seed"
  wait_for 600 "snapd seeded" ssh_vm 'systemctl is-active snapd.seeded.service' || fail "$id snapd never seeded"
  SEEDREV=$(ssh_vm "awk '/microk8s_/{gsub(/.*microk8s_|\\.snap/,\"\"); print}' /var/lib/snapd/seed/seed.yaml" || true)
  GOTREV=$(ssh_vm "snap list microk8s 2>/dev/null | awk 'NR==2{print \$3}'" || true)
  [ -n "$GOTREV" ] && [ "$GOTREV" = "$SEEDREV" ] && pass "$id MicroK8s from the seed (rev $GOTREV)" || fail "$id MicroK8s rev '$GOTREV' vs seed '$SEEDREV'"
  wait_for 1500 "first boot package install" ssh_vm 'test -e /var/lib/quotient-os/.firstboot-done' || fail "$id first boot did not finish"
  sudo_vm "cat /var/log/quotient-os-firstboot.log" > "$LOGS/$id-firstboot.log" 2>&1 || true
  ssh_vm 'test -x /usr/bin/quotient' && pass "$id quotient-server-tools installed" || fail "$id no quotient CLI"
  wait_for 1500 "mainframe healthy (/api/health 200)" ssh_vm 'test -f /var/lib/quotient/.configured && curl -s -o /dev/null -w "%{http_code}" http://localhost/api/health | grep -q 200' \
    && pass "$id healthy" || fail "$id not healthy"
  sudo_vm "quotient setup-code" 2>/dev/null | grep -q 'http://' && pass "$id setup code present" || fail "$id no setup code"
  sudo_vm "ufw status" | grep -q 'Status: active' && pass "$id ufw active" || fail "$id ufw not active"
  sudo_vm "ufw status" | grep -qE '^80(/tcp)? ' && pass "$id ufw allows 80" || fail "$id ufw has no 80 allow"
  ssh_vm 'systemctl is-active quotient-console.service' | grep -q active && pass "$id status console on tty1" || fail "$id console not active"
  ssh_vm 'systemctl is-active getty@tty1.service' | grep -q inactive && pass "$id no getty on tty1" || fail "$id getty on tty1"
  TELEM=$(ssh_vm "dpkg-query -W -f='\${Package} ' ubuntu-report apport whoopsie popularity-contest ubuntu-advantage-tools ubuntu-pro-client 2>/dev/null" || true)
  [ -z "$TELEM" ] && pass "$id no telemetry packages" || fail "$id telemetry packages: $TELEM"
  ssh_vm 'systemctl is-active NetworkManager avahi-daemon ssh' | grep -vq active && fail "$id a base service is down" || pass "$id NetworkManager, Avahi, SSH active"
  ssh_vm 'test -f /etc/quotient/install.conf && grep -q "^http_port=80" /etc/quotient/install.conf' && pass "$id install.conf preseeded" || fail "$id install.conf missing"
  ssh_vm 'test ! -e /usr/bin/calamares && test ! -e /usr/lib/quotient-os/quotient-os-install.sh' && pass "$id no live-layer files on disk" || fail "$id live files leaked into the install"

  log "Reboot"
  sudo_vm "systemctl reboot" >/dev/null 2>&1 || true
  sleep 20
  wait_for 300 "SSH after reboot" ssh_vm true || { fail "$id no SSH after reboot"; return; }
  wait_for 900 "healthy after reboot" ssh_vm 'curl -s -o /dev/null -w "%{http_code}" http://localhost/api/health | grep -q 200' \
    && pass "$id healthy after reboot" || fail "$id not healthy after reboot"
  sudo_vm "journalctl -u quotient-configure --no-pager" > "$LOGS/$id-configure.journal" 2>&1 || true
  sudo_vm "journalctl -b -1 --no-pager" > "$LOGS/$id-firstboot.journal" 2>&1 || true
  sudo_vm "quotient status" > "$LOGS/$id-status.txt" 2>&1 || true
  [ "$KEEP" = 1 ] || lxc delete -f "$vm"
}

for s in $(echo "$SCENARIOS" | tr ',' ' '); do
  case "$s" in
    O1) scenario O1 false ;;
    O3) scenario O3 true ;;
    *) echo "unknown scenario $s" >&2; FAILED=1 ;;
  esac
done
if [ "$FAILED" = 0 ]; then log "ALL PASS"; else log "FAILURES (see $RUNLOG)"; exit 1; fi
