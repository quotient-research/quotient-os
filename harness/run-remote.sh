#!/usr/bin/env bash
# Sync this repo to the LXD host (ep-ai), build the ISO there and run the
# harness, detached. Logs come back with --collect.
#
#   ./run-remote.sh [--host ep-ai] [--channel dev] [--scenarios O1,O2,O3]
#                   [--build full|keep-chroot|from-boot|none] [--keep]
#   ./run-remote.sh --attach STAMP      follow a run
#   ./run-remote.sh --collect STAMP     copy its logs and screenshots to harness/logs/STAMP
#
# --build keep-chroot reuses the debootstrap chroot (package changes, ~8 min);
# from-boot reuses the squashfs images (GRUB/EFI/answers only, ~2 min);
# none runs the harness on the last ISO.
set -euo pipefail
HOST=ep-ai; CHANNEL=dev; SCENARIOS=O1; BUILD=full; ATTACH=""; COLLECT=""; EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --scenarios) SCENARIOS="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --no-build) BUILD=none; shift ;;
    --attach) ATTACH="$2"; shift 2 ;;
    --collect) COLLECT="$2"; shift 2 ;;
    --keep) EXTRA="$EXTRA --keep"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE=quotient-os
if [ -n "$ATTACH" ]; then
  ssh -t "$HOST" "tail -f -n +1 ~/$REMOTE/harness/logs/$ATTACH/run.log"; exit 0
fi
if [ -n "$COLLECT" ]; then
  mkdir -p "$HERE/logs/$COLLECT"
  rsync -az --exclude '*.iso' --exclude '*.qcow2' --exclude '*.fd' --exclude id_ed25519 "$HOST:$REMOTE/harness/logs/$COLLECT/" "$HERE/logs/$COLLECT/"
  ls "$HERE/logs/$COLLECT"; exit 0
fi
case "$BUILD" in
  full) BUILD_FLAGS="" ;;
  keep-chroot) BUILD_FLAGS="--keep-chroot" ;;
  from-boot) BUILD_FLAGS="--from-boot" ;;
  none) BUILD_FLAGS="" ;;
  *) echo "--build must be full, keep-chroot, from-boot or none" >&2; exit 2 ;;
esac
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
rsync -az --delete --exclude out/ --exclude logs/ --exclude results/ --exclude .git/ "$HERE/.." "$HOST:$REMOTE/"
ssh "$HOST" "chmod +x ~/$REMOTE/build/*.sh ~/$REMOTE/harness/*.sh; mkdir -p ~/$REMOTE/harness/logs/$STAMP"
# Everything the remote shell runs is quoted once here; stdin is closed so lxc
# never waits on it and the ssh session returns at once.
# shellcheck disable=SC2029
ssh "$HOST" "(setsid nohup bash -c '
  cd ~/$REMOTE
  L=harness/logs/$STAMP
  if [ $BUILD != none ]; then
    sudo ./build/build-iso.sh $BUILD_FLAGS --channel $CHANNEL --out out > \$L/build.log 2>&1 || { echo BUILD FAILED >> \$L/run.log; exit 1; }
  fi
  ISO=\$(ls -t out/quotient-mainframe-os-*-amd64.iso | head -1)
  ./harness/os-harness.sh run --iso \$ISO --scenarios $SCENARIOS --logs \$L $EXTRA
' > /dev/null 2>&1 </dev/null &)"
echo "started on $HOST: logs $STAMP"
echo "follow:  $0 --attach $STAMP"
echo "collect: $0 --collect $STAMP"
