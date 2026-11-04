#!/usr/bin/env bash
# Sync this repo to the LXD host (ep-ai), build the ISO there and run the
# harness, detached. Logs come back to harness/logs/<stamp>/.
#
#   ./run-remote.sh [--host ep-ai] [--channel dev] [--scenarios O1,O3] [--no-build] [--attach STAMP]
set -euo pipefail
HOST=ep-ai; CHANNEL=dev; SCENARIOS=O1; BUILD=1; ATTACH=""; EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --scenarios) SCENARIOS="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --attach) ATTACH="$2"; shift 2 ;;
    --keep) EXTRA="$EXTRA --keep"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE=quotient-os
if [ -n "$ATTACH" ]; then
  ssh -t "$HOST" "tail -f -n +1 ~/$REMOTE/harness/logs/$ATTACH/run.log"
  exit 0
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
rsync -az --delete --exclude out/ --exclude logs/ --exclude .git/ "$HERE/.." "$HOST:$REMOTE/"
ssh "$HOST" "chmod +x ~/$REMOTE/build/*.sh ~/$REMOTE/harness/*.sh; mkdir -p ~/$REMOTE/harness/logs/$STAMP"
# shellcheck disable=SC2029
ssh "$HOST" "(setsid nohup bash -c '
  cd ~/$REMOTE
  L=harness/logs/$STAMP
  if [ $BUILD = 1 ]; then sudo ./build/build-iso.sh --channel $CHANNEL --out out > \$L/build.log 2>&1 || { echo BUILD FAILED >> \$L/run.log; exit 1; }; fi
  ISO=\$(ls -t out/quotientos-*-amd64.iso | head -1)
  ./harness/os-harness.sh run --iso \$ISO --scenarios $SCENARIOS --logs \$L $EXTRA
' > /dev/null 2>&1 &)"
echo "started on $HOST: logs $STAMP"
echo "follow:  $0 --attach $STAMP"
echo "collect: rsync -az $HOST:$REMOTE/harness/logs/$STAMP/ $HERE/logs/$STAMP/"
