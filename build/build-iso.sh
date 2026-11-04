#!/usr/bin/env bash
# Build the QuotientOS ISO: a minimal Ubuntu LTS that installs itself as a
# headless Quotient Mainframe. Run as root on an Ubuntu 26.04 host (ep-ai).
#
#   sudo ./build-iso.sh [--channel stable|preview|dev] [--work DIR] [--out DIR]
#                       [--no-seed] [--keep-chroot] [--version X.Y.Z]
#
# Layout of the result (hybrid BIOS + UEFI ISO, Secure Boot capable because
# only Ubuntu's signed shim, GRUB and kernel are used):
#   /live/10-base.squashfs   the installed system (what the installer unpacks)
#   /live/20-live.squashfs   the live-only layer (live-boot, Calamares, cage)
#   /live/vmlinuz, /live/initrd.img
#   /boot/grub/grub.cfg      BIOS + UEFI menu
#   /EFI/boot/efiboot.img    ESP image with shim + signed grub
#   /quotient/               (harness only) answers.conf for unattended installs
set -euo pipefail

CHANNEL=stable
WORK=/var/tmp/quotient-os
OUT=""
SEED=1
KEEP_CHROOT=0
VERSION=""
SUITE=resolute
MIRROR=http://archive.ubuntu.com/ubuntu
MICROK8S_CHANNEL=1.35/stable
REPO_URL=https://quotient-research.github.io/quotient-server-tools/apt-repo
REPO_KEY_FPR=AE772CBCB3BC29B247A794256781AAC9BFEA7E51

ANSWERS=""
REMASTER=0
FROM_BOOT=0
ISO_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --answers) ANSWERS="$2"; shift 2 ;;       # put an unattended answers file on the medium (harness)
    --remaster) REMASTER=1; shift ;;         # only rebuild the ISO from the last build tree
    --from-boot) FROM_BOOT=1; shift ;;       # reuse the squashfs images, redo the boot files and the ISO
    --iso-out) ISO_OUT="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-seed) SEED=0; shift ;;
    --keep-chroot) KEEP_CHROOT=1; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --suite) SUITE="$2"; shift 2 ;;
    -h|--help) sed -n 2,20p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../out}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for t in debootstrap mksquashfs xorriso grub-mkimage mkfs.vfat mcopy snap; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

VERSION=${VERSION:-$(date -u +%Y.%m.%d)}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CHROOT=$WORK/chroot
ISO_DIR=$WORK/iso
LIVE_UPPER=$WORK/live-upper
LIVE_WORK=$WORK/live-work
MERGED=$WORK/merged
APT_CACHE=$WORK/apt-cache
EFI_IMG=$ISO_DIR/EFI/boot/efiboot.img
mkdir -p "$WORK" "$OUT" "$APT_CACHE"
LOG=$OUT/build-$STAMP.log
exec > >(tee -a "$LOG") 2>&1

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  set +e
  for d in "$MERGED" "$CHROOT"; do
    for m in dev/pts dev proc sys run; do
      mountpoint -q "$d/$m" 2>/dev/null && umount -l "$d/$m"
    done
    mountpoint -q "$d/var/cache/apt/archives" 2>/dev/null && umount -l "$d/var/cache/apt/archives"
  done
  mountpoint -q "$MERGED" 2>/dev/null && umount -l "$MERGED"
}
trap cleanup EXIT

# Run a command inside a chroot with the pseudo filesystems and the shared
# APT cache mounted, services prevented from starting, and no prompts.
in_chroot() {
  local root=$1; shift
  for m in proc sys dev dev/pts run; do
    mkdir -p "$root/$m"
    mountpoint -q "$root/$m" || case $m in
      proc) mount -t proc proc "$root/proc" ;;
      sys) mount -t sysfs sys "$root/sys" ;;
      dev) mount --bind /dev "$root/dev" ;;
      dev/pts) mount --bind /dev/pts "$root/dev/pts" ;;
      run) mount -t tmpfs tmpfs "$root/run" ;;
    esac
  done
  mkdir -p "$root/var/cache/apt/archives"
  mountpoint -q "$root/var/cache/apt/archives" || mount --bind "$APT_CACHE" "$root/var/cache/apt/archives"
  printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"; chmod +x "$root/usr/sbin/policy-rc.d"
  cp /etc/resolv.conf "$root/etc/resolv.conf.build" && mv "$root/etc/resolv.conf.build" "$root/etc/resolv.conf"
  DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8 \
    chroot "$root" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

leave_chroot() {
  local root=$1
  rm -f "$root/usr/sbin/policy-rc.d"
  mountpoint -q "$root/var/cache/apt/archives" && umount -l "$root/var/cache/apt/archives"
  for m in run dev/pts dev sys proc; do
    mountpoint -q "$root/$m" && umount -l "$root/$m"
  done
  return 0
}

if [ "$REMASTER" = 1 ]; then
  [ -f "$ISO_DIR/.disk/quotient-os" ] || die "no build tree at $ISO_DIR to remaster"
  VERSION=$(awk -F= '/^version=/{print $2}' "$ISO_DIR/.disk/quotient-os")
  CHANNEL=$(awk -F= '/^channel=/{print $2}' "$ISO_DIR/.disk/quotient-os")
  DEB_VERSION=$(awk -F= '/^package=/{print $2}' "$ISO_DIR/.disk/quotient-os")
fi

if [ "$FROM_BOOT" = 1 ]; then
  [ -f "$ISO_DIR/live/20-live.squashfs" ] || die "no squashfs images at $ISO_DIR/live to reuse"
  read -r _ VERSION CHANNEL _ DEB_VERSION < <(tr -d '(),' < "$CHROOT/etc/quotient-os-release")
  log "Reusing images (QuotientOS $VERSION, $CHANNEL, package $DEB_VERSION)"
fi

if [ "$REMASTER" = 0 ] && [ "$FROM_BOOT" = 0 ]; then
# ---------------------------------------------------------------- 1. base
if [ -f "$CHROOT/.debootstrap-done" ] && [ "$KEEP_CHROOT" = 1 ]; then
  log "Reusing debootstrap chroot at $CHROOT"
else
  log "debootstrap $SUITE into $CHROOT"
  rm -rf "$CHROOT"; mkdir -p "$CHROOT"
  debootstrap --variant=minbase --arch=amd64 --components=main,restricted,universe \
    --cache-dir="$APT_CACHE" "$SUITE" "$CHROOT" "$MIRROR"
  touch "$CHROOT/.debootstrap-done"
fi

log "APT sources, locale, base packages"
cat > "$CHROOT/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
rm -f "$CHROOT/etc/apt/sources.list"
echo "quotientos" > "$CHROOT/etc/hostname"
# Kernel and shim postinsts want these; the installer rewrites them.
mkdir -p "$CHROOT/boot/efi"
in_chroot "$CHROOT" apt-get update -qq
in_chroot "$CHROOT" apt-get install -y -qq --no-install-recommends locales
in_chroot "$CHROOT" sh -c 'echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen >/dev/null && update-locale LANG=en_US.UTF-8'
in_chroot "$CHROOT" apt-get install -y -qq --no-install-recommends \
  $(grep -v '^#' "$HERE/packages-base.txt" | tr '\n' ' ')

# Ubuntu's linux-firmware metapackage pulls every vendor set (~690 MB,
# pre-compressed, so the squashfs can't shrink it). A Mainframe is an x86 PC
# with a text console: it needs CPU microcode, Wi-Fi/Ethernet/USB/storage
# firmware, not datacenter switch ASICs, phone SoCs or GPU acceleration blobs
# (the console runs on simpledrm without them). The packages stay installed,
# only their files are dropped; an upgrade may bring some back on disk, which
# is harmless.
log "Trimming firmware the Mainframe never loads"
FW=$CHROOT/usr/lib/firmware
du -sm "$FW" | awk '{print "  before: "$1" MB"}'
rm -rf "$FW"/qcom "$FW"/mellanox "$FW"/mrvl/prestera "$FW"/nvidia "$FW"/amdgpu "$FW"/radeon \
       "$FW"/i915 "$FW"/xe "$FW"/netronome "$FW"/qed "$FW"/dpaa2 "$FW"/ti-connectivity "$FW"/cirrus \
       "$FW"/intel/ipu "$FW"/intel/vsc "$FW"/intel/vpu "$FW"/intel/ish "$FW"/intel/qat \
       "$FW"/amdnpu "$FW"/amdtee "$FW"/qlogic "$FW"/cxgb4 "$FW"/liquidio "$FW"/bnx2x "$FW"/cavium "$FW"/imx "$FW"/meson "$FW"/rockchip "$FW"/ti "$FW"/microchip
du -sm "$FW" | awk '{print "  after:  "$1" MB"}'

log "Quotient APT source ($CHANNEL) and the package for first boot"
KEY_TMP=$(mktemp)
curl -fsSL "$REPO_URL/repo.gpg" -o "$KEY_TMP"
FPR=$(gpg --show-keys --with-colons "$KEY_TMP" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
[ "$FPR" = "$REPO_KEY_FPR" ] || die "Quotient APT key fingerprint mismatch: $FPR"
gpg --dearmor < "$KEY_TMP" > "$CHROOT/usr/share/keyrings/quotient.gpg"; rm -f "$KEY_TMP"
chmod 644 "$CHROOT/usr/share/keyrings/quotient.gpg"
echo "deb [signed-by=/usr/share/keyrings/quotient.gpg] $REPO_URL $CHANNEL main" > "$CHROOT/etc/apt/sources.list.d/quotient.list"
in_chroot "$CHROOT" apt-get update -qq
mkdir -p "$CHROOT/var/lib/quotient-os"
rm -f "$CHROOT"/var/lib/quotient-os/quotient-server-tools_*.deb
in_chroot "$CHROOT" sh -c 'cd /var/lib/quotient-os && apt-get download quotient-server-tools >/dev/null'
DEB_VERSION=$(dpkg-deb -f "$CHROOT"/var/lib/quotient-os/quotient-server-tools_*.deb Version)
echo "$CHANNEL" > "$CHROOT/var/lib/quotient-os/channel"
log "Bundled quotient-server-tools $DEB_VERSION ($CHANNEL)"

if [ "$SEED" = 1 ]; then
  log "Seeding the MicroK8s snap ($MICROK8S_CHANNEL) so first boot needs no download"
  SEED_DIR=$CHROOT/var/lib/snapd/seed
  rm -rf "$SEED_DIR"; mkdir -p "$SEED_DIR/snaps" "$SEED_DIR/assertions"
  SNAP_DL=$WORK/snaps; mkdir -p "$SNAP_DL"
  ( cd "$SNAP_DL"
    snap download microk8s --channel="$MICROK8S_CHANNEL" --basename=microk8s >/dev/null
    BASE=$(unsquashfs -cat microk8s.snap meta/snap.yaml | awk '/^base:/{print $2}')
    BASE=${BASE:-core22}
    snap download "$BASE" --basename="$BASE" >/dev/null
    snap download snapd --basename=snapd >/dev/null
    echo "$BASE" > base.name )
  BASE=$(cat "$SNAP_DL/base.name")
  # snapd refuses a seed without a model. Classic images use the generic
  # "generic-classic" model; ship it with its signing key and account.
  ( cd "$SNAP_DL"
    snap known --remote model series=16 brand-id=generic model=generic-classic > model.assert
    KEYID=$(awk '/^sign-key-sha3-384:/{print $2}' model.assert)
    snap known --remote account-key public-key-sha3-384="$KEYID" > key.assert
    snap known --remote account account-id=generic > account.assert
    [ -s model.assert ] && [ -s key.assert ] && [ -s account.assert ] || { echo "could not fetch the generic-classic model assertions" >&2; exit 1; }
    # A bundle is assertions separated by exactly one blank line.
    for f in account key model; do sed -e '${/^$/d}' "$f.assert"; echo; done > model )
  cp "$SNAP_DL/model" "$SEED_DIR/assertions/model"
  for s in snapd "$BASE" microk8s; do
    rev=$(grep -E '^snap-revision:' "$SNAP_DL/$s.assert" | head -1 | awk '{print $2}')
    cp "$SNAP_DL/$s.snap" "$SEED_DIR/snaps/${s}_${rev}.snap"
    cp "$SNAP_DL/$s.assert" "$SEED_DIR/assertions/${s}_${rev}.assert"
    eval "REV_$(echo "$s" | tr - _)=$rev"
  done
  cat > "$SEED_DIR/seed.yaml" <<EOF
snaps:
  - name: snapd
    channel: stable
    file: snapd_${REV_snapd}.snap
  - name: $BASE
    channel: stable
    file: ${BASE}_$(eval echo "\$REV_$(echo "$BASE" | tr - _)").snap
  - name: microk8s
    channel: $MICROK8S_CHANNEL
    classic: true
    file: microk8s_${REV_microk8s}.snap
EOF
fi

log "Installed-system overlay and defaults"
cp -a "$HERE/rootfs/." "$CHROOT/"
chmod +x "$CHROOT"/usr/lib/quotient-os/*

log "Brand assets: Jost (OFL), the Q mark as PNG, the Plymouth theme, the status console"
# Jost is not packaged; IBM Plex is (fonts-ibm-plex, live layer). Fetched once
# into the work dir, pinned by sha256 so a changed upstream file stops the build.
JOST=$WORK/Jost[wght].ttf
if [ ! -s "$JOST" ]; then
  curl -fsSL "https://github.com/google/fonts/raw/main/ofl/jost/Jost%5Bwght%5D.ttf" -o "$JOST"
fi
mkdir -p "$CHROOT/usr/share/fonts/truetype/jost" "$CHROOT/usr/share/doc/fonts-jost"
cp "$JOST" "$CHROOT/usr/share/fonts/truetype/jost/Jost[wght].ttf"
curl -fsSL "https://github.com/google/fonts/raw/main/ofl/jost/OFL.txt" -o "$CHROOT/usr/share/doc/fonts-jost/OFL.txt" || true
PLY=$CHROOT/usr/share/plymouth/themes/quotient
rsvg-convert -w 128 -h 128 "$HERE/live/etc/calamares/branding/quotient/quotient-mark.svg" -o "$PLY/mark.png"
rsvg-convert "$PLY/track.svg" -o "$PLY/track.png"; rsvg-convert "$PLY/fill.svg" -o "$PLY/fill.png"
rm -f "$PLY"/*.svg
# Ubuntu picks the splash through alternatives (no plymouth-set-default-theme).
in_chroot "$CHROOT" update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/quotient/quotient.plymouth 200 >/dev/null
in_chroot "$CHROOT" update-alternatives --set default.plymouth /usr/share/plymouth/themes/quotient/quotient.plymouth >/dev/null
# The status console (tty1) is a Go program; console.sh is the bash fallback.
rm -f "$CHROOT/usr/lib/quotient-os/console"
if command -v go >/dev/null; then
  ( cd "$HERE/../console" && CGO_ENABLED=0 GOFLAGS=-mod=mod go build -trimpath -ldflags="-s -w" -o "$CHROOT/usr/lib/quotient-os/console" . ) \
    && log "console built with $(go version | awk '{print $3}')" || die "console build failed"
else
  log "no Go on this host: shipping the bash console"
  cp "$CHROOT/usr/lib/quotient-os/console.sh" "$CHROOT/usr/lib/quotient-os/console"
fi
chmod +x "$CHROOT"/usr/lib/quotient-os/*
# Nothing phones home but Quotient and Ubuntu security updates.
in_chroot "$CHROOT" sh -c 'systemctl mask motd-news.timer motd-news.service >/dev/null 2>&1 || true'
rm -f "$CHROOT"/etc/update-motd.d/50-motd-news "$CHROOT"/etc/update-motd.d/10-help-text "$CHROOT"/etc/update-motd.d/90-updates-available 2>/dev/null || true
in_chroot "$CHROOT" systemctl enable NetworkManager ssh avahi-daemon quotient-os-firstboot quotient-console >/dev/null 2>&1 || true
in_chroot "$CHROOT" apt-get clean
rm -f "$CHROOT/etc/resolv.conf"; ln -s ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
rm -f "$CHROOT/etc/machine-id"; : > "$CHROOT/etc/machine-id"
echo "QuotientOS $VERSION ($CHANNEL, quotient-server-tools $DEB_VERSION)" > "$CHROOT/etc/quotient-os-release"
leave_chroot "$CHROOT"

log "Base squashfs"
# The image's root inode is the chroot directory: it must be root 0755, or
# snapd (and more) refuse to work on the installed system.
chown root:root "$CHROOT"; chmod 755 "$CHROOT"
rm -rf "$ISO_DIR"; mkdir -p "$ISO_DIR/live" "$ISO_DIR/boot/grub" "$ISO_DIR/EFI/boot" "$ISO_DIR/.disk"
mksquashfs "$CHROOT" "$ISO_DIR/live/10-base.squashfs" -comp zstd -Xcompression-level 15 -noappend -quiet \
  -e .debootstrap-done -wildcards -e 'var/cache/apt/archives/*.deb' -e 'boot/efi/*'

# ---------------------------------------------------------------- 2. live layer
log "Live layer (live-boot, Calamares, cage) as an overlay on the base"
rm -rf "$LIVE_UPPER" "$LIVE_WORK" "$MERGED"; mkdir -p "$LIVE_UPPER" "$LIVE_WORK" "$MERGED"
mount -t overlay overlay -o "lowerdir=$CHROOT,upperdir=$LIVE_UPPER,workdir=$LIVE_WORK" "$MERGED"
in_chroot "$MERGED" apt-get install -y -qq --no-install-recommends \
  $(grep -v '^#' "$HERE/packages-live.txt" | sed 's/ *#.*//' | tr '\n' ' ')
cp -a "$HERE/live/." "$MERGED/"
chmod +x "$MERGED"/usr/lib/quotient-os/*
# Qt gives the SVG mark no intrinsic size; the installer uses PNGs made here.
BR=$MERGED/etc/calamares/branding/quotient
rsvg-convert -w 64 -h 64 "$BR/quotient-mark.svg" -o "$BR/quotient-mark-64.png"
rsvg-convert -w 160 -h 160 "$BR/quotient-mark.svg" -o "$BR/quotient-mark-160.png"
in_chroot "$MERGED" systemctl enable quotient-installer serial-getty@ttyS0 >/dev/null 2>&1 || true
in_chroot "$MERGED" systemctl disable quotient-os-firstboot quotient-console ssh >/dev/null 2>&1 || true
in_chroot "$MERGED" sh -c 'update-initramfs -u -k all >/dev/null 2>&1'
in_chroot "$MERGED" apt-get clean
KERNEL=$(ls "$MERGED"/boot/vmlinuz-* | sort -V | tail -1)
cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "${KERNEL/vmlinuz/initrd.img}" "$ISO_DIR/live/initrd.img"
leave_chroot "$MERGED"
umount "$MERGED"
mksquashfs "$LIVE_UPPER" "$ISO_DIR/live/20-live.squashfs" -comp zstd -Xcompression-level 15 -noappend -quiet \
  -wildcards -e 'var/cache/apt/archives/*.deb'

fi # FROM_BOOT

if [ "$REMASTER" = 0 ]; then
# ---------------------------------------------------------------- 3. boot
log "GRUB (BIOS) and the EFI image (shim + signed GRUB)"
mkdir -p "$ISO_DIR/boot/grub" "$ISO_DIR/EFI/boot" "$ISO_DIR/.disk"
cp "$HERE/grub/grub.cfg" "$ISO_DIR/boot/grub/grub.cfg"
sed -i "s/@VERSION@/$VERSION/g" "$ISO_DIR/boot/grub/grub.cfg"
mkdir -p "$ISO_DIR/boot/grub/i386-pc"
cp /usr/lib/grub/i386-pc/*.mod /usr/lib/grub/i386-pc/*.lst "$ISO_DIR/boot/grub/i386-pc/" 2>/dev/null || true
grub-mkimage -O i386-pc -o "$WORK/core.img" -p /boot/grub \
  biosdisk iso9660 part_gpt part_msdos normal configfile linux search search_label search_fs_file \
  ls echo test sleep all_video gfxterm font png loadenv
cat /usr/lib/grub/i386-pc/cdboot.img "$WORK/core.img" > "$ISO_DIR/boot/grub/i386-pc/eltorito.img"
cp /usr/share/grub/unicode.pf2 "$ISO_DIR/boot/grub/font.pf2" 2>/dev/null || true
# Menu theme: ink, the Q mark, Jost title (converted to GRUB's pf2), green selection.
THEME=$ISO_DIR/boot/grub/theme; mkdir -p "$THEME"
cp "$HERE/grub/theme/theme.txt" "$THEME/"
rsvg-convert -w 96 -h 96 "$HERE/live/etc/calamares/branding/quotient/quotient-mark.svg" -o "$THEME/mark.png"
rsvg-convert "$HERE/grub/theme/select_c.svg" -o "$THEME/select_c.png"
for part in n s e w ne nw se sw; do cp "$THEME/select_c.png" "$THEME/select_$part.png"; done
grub-mkfont -s 30 -o "$THEME/jost30.pf2" "$WORK/Jost[wght].ttf" 2>/dev/null || { log "grub-mkfont failed; title in Unicode"; sed -i 's/font = "Jost Regular 30"/font = "Unicode Regular 16"/' "$THEME/theme.txt"; }
cp /usr/share/grub/unicode.pf2 "$THEME/unicode.pf2"

EFI_IMG=$ISO_DIR/EFI/boot/efiboot.img
rm -f "$EFI_IMG"; truncate -s 24M "$EFI_IMG"
mkfs.vfat -F 16 -n EFIBOOT "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::/EFI ::/EFI/boot ::/EFI/ubuntu
# shimx64.efi.signed is an alternatives symlink inside the chroot: resolve it there.
SHIM=$CHROOT$(chroot "$CHROOT" readlink -f /usr/lib/shim/shimx64.efi.signed)
GRUB_EFI=$CHROOT$(chroot "$CHROOT" readlink -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed)
MOKM=$CHROOT/usr/lib/shim/mmx64.efi   # MokManager ships signed under its plain name
# Only shim, GRUB and MokManager. Never fbx64.efi (shim's fallback loader): on
# removable media it takes over from shim, finds no BOOT*.CSV and resets the machine.
mcopy -i "$EFI_IMG" "$SHIM" ::/EFI/boot/bootx64.efi
[ -f "$MOKM" ] && mcopy -i "$EFI_IMG" "$MOKM" ::/EFI/boot/mmx64.efi
mcopy -i "$EFI_IMG" "$GRUB_EFI" ::/EFI/boot/grubx64.efi
mcopy -i "$EFI_IMG" "$HERE/grub/grub-efi.cfg" ::/EFI/ubuntu/grub.cfg
# The same loaders on the ISO filesystem for firmware that reads the ISO9660 side.
rm -f "$ISO_DIR"/EFI/boot/*.efi
cp "$SHIM" "$ISO_DIR/EFI/boot/bootx64.efi"
[ -f "$MOKM" ] && cp "$MOKM" "$ISO_DIR/EFI/boot/mmx64.efi"
cp "$GRUB_EFI" "$ISO_DIR/EFI/boot/grubx64.efi"
mkdir -p "$ISO_DIR/EFI/ubuntu"; cp "$HERE/grub/grub-efi.cfg" "$ISO_DIR/EFI/ubuntu/grub.cfg"

echo "QuotientOS $VERSION" > "$ISO_DIR/.disk/info"
printf 'version=%s\nchannel=%s\npackage=%s\nbuilt=%s\n' "$VERSION" "$CHANNEL" "$DEB_VERSION" "$STAMP" > "$ISO_DIR/.disk/quotient-os"

fi # REMASTER

# The menu is cheap to refresh on every remaster.
cp "$HERE/grub/grub.cfg" "$ISO_DIR/boot/grub/grub.cfg"
sed -i "s/@VERSION@/$VERSION/g" "$ISO_DIR/boot/grub/grub.cfg"
rm -rf "$ISO_DIR/quotient"
if [ -n "$ANSWERS" ]; then
  mkdir -p "$ISO_DIR/quotient"; cp "$ANSWERS" "$ISO_DIR/quotient/answers.conf"
  log "Unattended answers placed on the medium"
fi
ISO=${ISO_OUT:-$OUT/quotientos-$VERSION-$CHANNEL-amd64.iso}
log "ISO $ISO"
xorriso -as mkisofs -quiet -r -V QUOTIENTOS -o "$ISO" \
  -J -joliet-long -l -iso-level 3 -partition_offset 16 \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img --mbr-force-bootable \
  -append_partition 2 0xEF "$EFI_IMG" -appended_part_as_gpt \
  -c /boot.catalog \
  -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
  "$ISO_DIR"
( cd "$(dirname "$ISO")" && sha256sum "$(basename "$ISO")" > "$(basename "$ISO").sha256" )
ls -lh "$ISO"
[ "$KEEP_CHROOT" = 1 ] || rm -rf "$LIVE_UPPER" "$LIVE_WORK" "$MERGED"
log "Done: $ISO"
echo "$ISO"
