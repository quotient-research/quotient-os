#!/usr/bin/env bash
# Unattended QuotientOS install from the live system. Reads an answers file
# (key=value) and installs the base squashfs to one disk, UEFI + BIOS.
#
#   disk=/dev/sda          the whole disk; erased
#   name=lakehouse         the Mainframe's name (hostname)
#   user=eric              owner account (console and SSH)
#   password=...           owner password
#   locale=en_US.UTF-8     optional
#   keyboard=us            optional
#   timezone=Etc/UTC       optional
#   poweroff=1             optional: power off when done (default: reboot)
set -euo pipefail
ANSWERS=${1:-/run/live/medium/quotient/answers.conf}
LOG=/var/log/quotient-os-install.log
# Progress goes to the log and to the console (tty1, or the serial port when
# the kernel command line names one), so an unattended install can be watched.
exec > >(tee -a "$LOG" /dev/console) 2>&1
log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -r "$ANSWERS" ] || die "no answers file at $ANSWERS"
# key=value per line; values may contain spaces (an SSH public key) and are
# never evaluated as shell.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  key=${line%%=*}; value=${line#*=}
  case "$key" in
    disk|name|user|password|locale|keyboard|timezone|poweroff|ssh_key|serial) printf -v "$key" '%s' "$value" ;;
    *) log "ignoring unknown answer '$key'" ;;
  esac
done < "$ANSWERS"
: "${disk:?disk= is required}" "${name:?name= is required}" "${user:?user= is required}" "${password:?password= is required}"
locale=${locale:-en_US.UTF-8}; keyboard=${keyboard:-us}; timezone=${timezone:-Etc/UTC}; poweroff=${poweroff:-0}
[ -b "$disk" ] || die "$disk is not a block device"
MEDIUM=/run/live/medium
BASE=$MEDIUM/live/10-base.squashfs
[ -r "$BASE" ] || die "no base image at $BASE"
T=/target

log "Partitioning $disk (GPT: EFI 512M, BIOS boot 1M, root)"
swapoff -a 2>/dev/null || true
umount -R "$T" 2>/dev/null || true
sgdisk --zap-all "$disk" >/dev/null
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:EFI \
       -n 2:0:+1M   -t 2:ef02 -c 2:BIOSBOOT \
       -n 3:0:0     -t 3:8300 -c 3:quotient-root "$disk" >/dev/null
partprobe "$disk"; udevadm settle
p() { case "$disk" in *[0-9]) echo "${disk}p$1" ;; *) echo "${disk}$1" ;; esac; }
mkfs.vfat -F 32 -n EFI "$(p 1)" >/dev/null
mkfs.ext4 -q -F -L quotient-root "$(p 3)"

log "Unpacking the base system"
mkdir -p "$T"; mount "$(p 3)" "$T"
unsquashfs -f -d "$T" -no-progress "$BASE" >/dev/null
chown root:root "$T"; chmod 755 "$T"
mkdir -p "$T/boot/efi"; mount "$(p 1)" "$T/boot/efi"

log "System settings: $name, $user, $locale, $keyboard, $timezone"
ROOT_UUID=$(blkid -s UUID -o value "$(p 3)"); EFI_UUID=$(blkid -s UUID -o value "$(p 1)")
cat > "$T/etc/fstab" <<EOF
UUID=$ROOT_UUID  /         ext4  defaults,errors=remount-ro  0 1
UUID=$EFI_UUID   /boot/efi vfat  umask=0077                  0 1
EOF
echo "$name" > "$T/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n\n::1\tlocalhost ip6-localhost ip6-loopback\n' "$name" > "$T/etc/hosts"
echo "LANG=$locale" > "$T/etc/default/locale"
sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$keyboard\"/" "$T/etc/default/keyboard"
ln -sf "/usr/share/zoneinfo/$timezone" "$T/etc/localtime"; echo "$timezone" > "$T/etc/timezone"

for m in proc sys dev dev/pts run; do mount --bind "/$m" "$T/$m"; done
ch() { chroot "$T" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }
ch sh -c "grep -q '^$locale' /etc/locale.gen || echo '$locale UTF-8' >> /etc/locale.gen; locale-gen >/dev/null"
ch systemd-machine-id-setup >/dev/null 2>&1 || true
ch useradd -m -s /bin/bash -G sudo,adm "$user"
printf '%s:%s\n' "$user" "$password" | ch chpasswd
ch passwd -l root >/dev/null
if [ -n "${ssh_key:-}" ]; then
  mkdir -p "$T/home/$user/.ssh"; echo "$ssh_key" > "$T/home/$user/.ssh/authorized_keys"
  chmod 700 "$T/home/$user/.ssh"; chmod 600 "$T/home/$user/.ssh/authorized_keys"
  ch chown -R "$user:$user" "/home/$user/.ssh"
fi

log "Bootloader (UEFI with Secure Boot, and BIOS)"
ch grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --uefi-secure-boot --removable --no-nvram >/dev/null 2>&1 || true
ch grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --uefi-secure-boot >/dev/null 2>&1 || log "no EFI variables (BIOS boot?); removable path installed"
ch grub-install --target=i386-pc "$disk" >/dev/null 2>&1 || log "BIOS grub-install skipped"
ch sh -c 'sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/; s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"/" /etc/default/grub; grep -q GRUB_DISTRIBUTOR /etc/default/grub && sed -i "s/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=QuotientOS/" /etc/default/grub'
# serial=1 (harness): kernel messages and a login on the serial port as well.
[ "${serial:-0}" = 1 ] && ch sh -c 'sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"console=tty1 console=ttyS0,115200n8\"/" /etc/default/grub'
ch update-initramfs -u -k all >/dev/null 2>&1
ch update-grub >/dev/null 2>&1

log "Quotient post-install"
ch /usr/lib/quotient-os/postinstall.sh

sync
for m in run dev/pts dev sys proc; do umount -l "$T/$m"; done
umount "$T/boot/efi"; umount "$T"
log "Install complete"
cp "$LOG" /dev/console 2>/dev/null || true
if [ "$poweroff" = 1 ]; then systemctl poweroff; else systemctl reboot; fi
