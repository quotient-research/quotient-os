#!/usr/bin/env bash
# QuotientOS install harness. Boots an ISO in a throwaway VM, installs, reboots
# into the disk and checks that the Mainframe comes up. Runs on ep-ai.
#
#   ./os-harness.sh run --iso FILE [--scenarios O1,O2,O3] [--keep] [--logs DIR]
#   ./os-harness.sh clean
#
# Scenarios
#   O1  unattended install in an LXD VM, Secure Boot off, reboot, healthy
#   O3  the same with Secure Boot on
#   O2  the graphical installer driven by keyboard over VNC in host QEMU
#       (LXD's QEMU has no VNC); a screenshot of every page, then the same
#       checks on the installed disk
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
  pkill -f "qemu-system-x86_64 -name qos-o2" || true
  exit 0
fi
[ "$CMD" = run ] || { sed -n 2,14p "$0"; exit 2; }
[ -r "$ISO" ] || { echo "no ISO at $ISO" >&2; exit 2; }
# One VM at a time on this host: our own lock, and the quotient-server install harness.
exec 9>/tmp/quotient-os-harness.lock
flock -n 9 || { echo "another QuotientOS harness run is in progress" >&2; exit 3; }
if pgrep -f 'install-harness/harness.sh run' >/dev/null; then echo "the quotient-server install harness is running" >&2; exit 3; fi

# Docker's FORWARD DROP policy on the host drops VM traffic unless the LXD
# bridge is allowed through DOCKER-USER; a host reboot loses these rules.
if sudo -n iptables -S DOCKER-USER >/dev/null 2>&1; then
  for d in i o; do
    sudo -n iptables -C DOCKER-USER -$d lxdbr0 -j ACCEPT 2>/dev/null || sudo -n iptables -I DOCKER-USER -$d lxdbr0 -j ACCEPT
  done
fi

NAME=lakehouse; USER_=owner; PASS=$(openssl rand -hex 8)
SSHKEY=$LOGS/id_ed25519; ssh-keygen -q -t ed25519 -N '' -f "$SSHKEY" </dev/null
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

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
serial=1
EOF
HISO=$LOGS/harness.iso
if echo "$SCENARIOS" | grep -qE 'O1|O3'; then
  log "Remastering $ISO with answers → $HISO"
  sudo "$HERE/../build/build-iso.sh" --remaster --answers "$ANS" --iso-out "$HISO" >"$LOGS/remaster.log" 2>&1 || { cat "$LOGS/remaster.log"; exit 1; }
fi

# How to reach the installed system: set per scenario.
SSH_TARGET=""; SSH_PORT=22; SSH_AUTH=()
ssh_vm() { "${SSH_AUTH[@]}" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" "$@"; }
sudo_vm() { "${SSH_AUTH[@]}" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" "echo '$PASS' | sudo -S -p '' $*"; }
wait_for() { # wait_for SECONDS DESCRIPTION CMD...
  local t=$1 d=$2; shift 2
  local start; start=$(date +%s)
  while ! "$@" >/dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge "$t" ]; then echo "timeout waiting for $d"; return 1; fi
    sleep 10
  done
  log "$d after $(( $(date +%s) - start ))s"
}

# The checks every scenario runs once the installed disk is up and reachable.
checks() { # checks ID SECUREBOOT(true|false)
  local id=$1 sb=$2
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
  # is-active exits 3 for an inactive unit; compare the text, don't pipe (pipefail).
  [ "$(ssh_vm 'systemctl is-active getty@tty1.service' || true)" = inactive ] && pass "$id no getty on tty1" || fail "$id getty on tty1"
  # dpkg-query lists packages it merely knows about; keep only installed ones.
  TELEM=$(ssh_vm "dpkg-query -W -f='\${Package} \${db:Status-Status}\n' ubuntu-report apport whoopsie popularity-contest ubuntu-advantage-tools ubuntu-pro-client 2>/dev/null | awk '\$2==\"installed\"{printf \"%s \", \$1}'" || true)
  [ -z "$TELEM" ] && pass "$id no telemetry packages" || fail "$id telemetry packages: $TELEM"
  ssh_vm 'systemctl is-active NetworkManager avahi-daemon ssh' | grep -vq active && fail "$id a base service is down" || pass "$id NetworkManager, Avahi, SSH active"
  ssh_vm 'test -f /etc/quotient/install.conf && grep -q "^http_port=80" /etc/quotient/install.conf' && pass "$id install.conf preseeded" || fail "$id install.conf missing"
  ssh_vm 'test ! -e /usr/bin/calamares && test ! -e /usr/lib/quotient-os/quotient-os-install.sh' && pass "$id no live-layer files on disk" || fail "$id live files leaked into the install"
  ssh_vm 'test ! -d /usr/lib/firmware/qcom && test ! -d /usr/lib/firmware/nvidia' && pass "$id trimmed firmware absent" || fail "$id trimmed firmware present"

  log "Reboot"
  sudo_vm "systemctl reboot" >/dev/null 2>&1 || true
  sleep 20
  wait_for 300 "SSH after reboot" ssh_vm true || { fail "$id no SSH after reboot"; return; }
  wait_for 900 "healthy after reboot" ssh_vm 'curl -s -o /dev/null -w "%{http_code}" http://localhost/api/health | grep -q 200' \
    && pass "$id healthy after reboot" || fail "$id not healthy after reboot"
  sudo_vm "journalctl -u quotient-configure --no-pager" > "$LOGS/$id-configure.journal" 2>&1 || true
  sudo_vm "journalctl -b -1 --no-pager" > "$LOGS/$id-firstboot.journal" 2>&1 || true
  sudo_vm "quotient status" > "$LOGS/$id-status.txt" 2>&1 || true
}

# Start an LXD VM with the serial console captured to a log (a VM's console is
# only readable live), detached so the harness can keep polling.
start_with_console() { # start_with_console VM LOGFILE
  (setsid nohup script -q -c "lxc start $1 --console" "$2" >/dev/null 2>&1 </dev/null &)
  sleep 3
}

scenario() { # scenario ID SECUREBOOT: unattended install in an LXD VM
  local id=$1 sb=$2 vm
  vm=qos-$(echo "$id" | tr 'A-Z' 'a-z')
  log "=== $id (secureboot=$sb) on $vm"
  lxc delete -f "$vm" >/dev/null 2>&1 || true
  lxc init "$vm" --empty --vm -c limits.cpu=3 -c limits.memory=4GiB -c "security.secureboot=$sb" -d root,size=30GiB >/dev/null </dev/null
  lxc config device add "$vm" iso disk source="$HISO" boot.priority=10 >/dev/null </dev/null
  start_with_console "$vm" "$LOGS/$id-install-console.log"
  log "Installing from the ISO (unattended)"
  sleep 60   # the VM must be seen RUNNING before STOPPED means "finished"
  if ! wait_for 1500 "install finished (VM powered off)" sh -c "lxc info $vm | grep -q 'Status: STOPPED'"; then
    fail "$id install did not finish"; return
  fi
  lxc config device remove "$vm" iso >/dev/null </dev/null
  start_with_console "$vm" "$LOGS/$id-boot-console.log"
  log "Booting the installed disk"
  # LXD records the lease under the instance name and shows it in `lxc list`.
  if ! wait_for 300 "DHCP lease for $vm" sh -c "lxc list $vm --format csv -c 4 | grep -qE '([0-9]+\.){3}[0-9]+'"; then
    fail "$id no DHCP lease"; return
  fi
  local ip; ip=$(lxc list "$vm" --format csv -c 4 | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)
  log "VM address $ip"
  SSH_TARGET="$USER_@$ip"; SSH_PORT=22; SSH_AUTH=()
  SSH_OPTS+=(-i "$SSHKEY")
  wait_for 300 "SSH" ssh_vm true || { fail "$id no SSH"; return; }
  checks "$id" "$sb"
  [ "$KEEP" = 1 ] || lxc delete -f "$vm"
}

# --- O2: the graphical installer -------------------------------------------
# Host QEMU with KVM, OVMF, virtio-vga, a VNC display on 127.0.0.1:5 and user
# networking with SSH forwarded to 127.0.0.1:2222. Keys go in with vncdo and
# screenshots come out with vncsnapshot. Calamares buttons have mnemonics
# (Alt+N next, Alt+B back); page contents are typed after a click into the
# first field.
VNC=127.0.0.1::5905
vnc_key() { "$HOME/.local/bin/vncdo" -s "$VNC" key "$1" >/dev/null 2>&1; sleep 1; }
vnc_type() { "$HOME/.local/bin/vncdo" -s "$VNC" type "$1" >/dev/null 2>&1; sleep 1; }
vnc_click() { "$HOME/.local/bin/vncdo" -s "$VNC" move "$1" "$2" click 1 >/dev/null 2>&1; sleep 1; }
shot() { vncsnapshot -quiet 127.0.0.1:5 "$LOGS/O2-$1.jpg" >/dev/null 2>&1 || true; }
qemu_gui() { # qemu_gui BOOT_ORDER
  (setsid nohup qemu-system-x86_64 -name qos-o2 -enable-kvm -m 4096 -smp 3 -cpu host -machine q35 \
     -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
     -drive if=pflash,format=raw,file="$LOGS/O2-vars.fd" \
     -drive file="$LOGS/O2-disk.qcow2",if=virtio,format=qcow2 \
     -cdrom "$ISO" -boot "$1" -device virtio-vga -vnc 127.0.0.1:5 -display none \
     -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
     -serial "unix:$LOGS/O2-serial.sock,server,nowait" -pidfile "$LOGS/O2-qemu.pid" >"$LOGS/O2-qemu.log" 2>&1 &)
  sleep 5
  # A two-way bridge to the live system's serial root login: output streams
  # into O2-serial.log, commands go in through serial_cmd (for log retrieval).
  (setsid nohup socat "PTY,link=$LOGS/O2-serial.pty,raw,echo=0" "UNIX-CONNECT:$LOGS/O2-serial.sock" >/dev/null 2>&1 </dev/null &)
  sleep 2
  (setsid nohup sh -c "cat '$LOGS/O2-serial.pty' >> '$LOGS/O2-serial.log'" >/dev/null 2>&1 </dev/null &)
}
serial_cmd() { printf '\r\n%s\r\n' "$1" > "$LOGS/O2-serial.pty" 2>/dev/null || true; }
# On a failed GUI install, pull the interesting lines of Calamares's own log.
dump_calamares_log() {
  serial_cmd "grep -vE 'reportProgress|Remaining modules' /root/.cache/calamares/session.log | grep -iE 'ERROR|WARNING|grub|bootloader|Failed|failed|exit code' | tail -40 | cut -c1-240; echo CALAMARES-LOG-END"
  sleep 8
  sed -n '/CALAMARES-LOG-END/q;p' "$LOGS/O2-serial.log" | grep -aE 'ERROR|WARNING|grub|bootloader|Failed|failed|exit code' | tail -40 > "$LOGS/O2-calamares-errors.log" || true
}
qemu_stop() { [ -f "$LOGS/O2-qemu.pid" ] && kill "$(cat "$LOGS/O2-qemu.pid")" 2>/dev/null || true; pkill -f "PTY,link=$LOGS/O2-serial.pty" 2>/dev/null || true; sleep 3; }

scenario_gui() {
  local id=O2
  log "=== O2 (graphical installer in host QEMU, VNC on :5)"
  for t in qemu-system-x86_64 vncsnapshot "$HOME/.local/bin/vncdo" sshpass; do
    command -v "$t" >/dev/null || { fail "O2 needs $t on this host"; return; }
  done
  pkill -f "qemu-system-x86_64 -name qos-o2" 2>/dev/null || true
  rm -f "$LOGS/O2-disk.qcow2"; qemu-img create -q -f qcow2 "$LOGS/O2-disk.qcow2" 30G
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$LOGS/O2-vars.fd"
  qemu_gui "order=c,once=d"
  log "Waiting for the welcome page"
  sleep 100; shot 1-welcome
  vnc_key alt-n; sleep 4; shot 2-locale
  vnc_key alt-n; sleep 4; shot 3-keyboard
  vnc_key alt-n; sleep 8; shot 4-disk           # erase + first disk preselected
  vnc_key alt-n; sleep 4; shot 5-users-empty
  # Users page: full name → login (auto) → hostname (auto) → password → repeat.
  vnc_click 640 120; vnc_type "Owner"; vnc_key tab; vnc_type "$USER_"; vnc_key tab; vnc_type "$NAME"
  vnc_key tab; vnc_type "$PASS"; vnc_key tab; vnc_type "$PASS"; sleep 2; shot 5-users
  vnc_key alt-n; sleep 4; shot 6-summary
  vnc_key alt-n; sleep 3; shot 7-confirm        # prompt-install dialog
  vnc_key alt-i; sleep 1; vnc_key enter; sleep 15; shot 8-installing
  log "Installing through the GUI"
  # Finished page: "Restart now" is checked; Done reboots. Wait for the serial
  # log to show the shutdown, up to 20 minutes, taking a screenshot every minute.
  # The progress page changes every minute (bar, slideshow); the finished and
  # the failed pages do not. Two identical screenshots in a row means it's done.
  local i=0 same=0
  while [ $i -lt 20 ]; do
    sleep 60; i=$((i+1)); shot "8-installing-$i"
    if [ $i -gt 1 ] && cmp -s "$LOGS/O2-8-installing-$i.jpg" "$LOGS/O2-8-installing-$((i-1)).jpg"; then
      same=$((same+1)); [ $same -ge 1 ] && break
    else
      same=0
    fi
    grep -aq "reboot: Restarting\|systemd-shutdown" "$LOGS/O2-serial.log" 2>/dev/null && break
  done
  shot 9-finished
  # Finished page: "Restart now" is checked, Done (Alt+D) reboots into the disk.
  vnc_key alt-d
  # Reboot into the disk (once=d is spent): QEMU restarts from the disk on its own.
  SSH_TARGET="$USER_@127.0.0.1"; SSH_PORT=2222; SSH_AUTH=(sshpass -p "$PASS")
  wait_for 600 "SSH on the installed disk" ssh_vm true || { fail "O2 no SSH after the GUI install"; shot 9-after; dump_calamares_log; [ "$KEEP" = 1 ] || qemu_stop; return; }
  checks O2 false
  [ "$KEEP" = 1 ] || qemu_stop
}

for s in $(echo "$SCENARIOS" | tr ',' ' '); do
  case "$s" in
    O1) scenario O1 false ;;
    O3) scenario O3 true ;;
    O2) scenario_gui ;;
    *) echo "unknown scenario $s" >&2; FAILED=1 ;;
  esac
done
if [ "$FAILED" = 0 ]; then log "ALL PASS"; else log "FAILURES (see $RUNLOG)"; exit 1; fi
