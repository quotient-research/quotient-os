#!/usr/bin/env bash
# Publish a built ISO: checksums, a GPG signature with the Quotient APT key,
# the files in the website's Azure storage (container "mainframe-os"), latest.json for
# the download page, and a GitHub Release carrying the checksum files.
#
#   ./publish.sh --iso out/quotient-mainframe-os-2026.11.04-stable-amd64.iso \
#                [--account stquotientwebprod] [--key KEY | env AZURE_STORAGE_KEY] \
#                [--no-sign] [--no-upload] [--no-release] [--repo quotient-research/quotient-os]
#
# The GPG key must already be in the keyring (release.yml imports it from the
# GPG_PRIVATE_KEY secret; by hand it is the owner's). Nothing here rebuilds.
set -euo pipefail
ISO=""; ACCOUNT=${AZURE_STORAGE_ACCOUNT:-stquotientwebprod}; KEY=${AZURE_STORAGE_KEY:-}
SIGN=1; UPLOAD=1; RELEASE=1; REPO=${GITHUB_REPOSITORY:-quotient-research/quotient-os}
CONTAINER=mainframe-os   # Azure needs 3-63 characters
REPO_KEY_FPR=AE772CBCB3BC29B247A794256781AAC9BFEA7E51
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --no-sign) SIGN=0; shift ;;
    --no-upload) UPLOAD=0; shift ;;
    --no-release) RELEASE=0; shift ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
[ -s "$ISO" ] || die "no ISO at '$ISO'"
DIR=$(cd "$(dirname "$ISO")" && pwd); NAME=$(basename "$ISO")
# quotient-mainframe-os-<version>-<channel>-amd64.iso
VERSION=$(echo "$NAME" | sed -n 's/^quotient-mainframe-os-\(.*\)-\(stable\|preview\|dev\)-amd64\.iso$/\1/p')
CHANNEL=$(echo "$NAME" | sed -n 's/^quotient-mainframe-os-.*-\(stable\|preview\|dev\)-amd64\.iso$/\1/p')
[ -n "$VERSION" ] && [ -n "$CHANNEL" ] || die "ISO name must be quotient-mainframe-os-<version>-<channel>-amd64.iso"
PACKAGE=$(xorriso -indev "$ISO" -osirrox on -extract /.disk/quotient-os "$DIR/.disk-quotient-os" >/dev/null 2>&1 \
  && awk -F= '/^package=/{print $2}' "$DIR/.disk-quotient-os"; rm -f "$DIR/.disk-quotient-os")
SIZE=$(stat -c %s "$ISO")

cd "$DIR"
log "SHA256SUMS"
sha256sum "$NAME" > SHA256SUMS
SHA=$(awk '{print $1}' SHA256SUMS)
rm -f SHA256SUMS.gpg; SIGFILE=""
if [ "$SIGN" = 1 ]; then
  log "Signing SHA256SUMS with the Quotient APT key"
  gpg --batch --list-secret-keys "$REPO_KEY_FPR" >/dev/null 2>&1 || die "the APT signing key $REPO_KEY_FPR is not in this keyring"
  gpg --batch --yes --armor --detach-sign --local-user "$REPO_KEY_FPR" --output SHA256SUMS.gpg SHA256SUMS
  gpg --batch --verify SHA256SUMS.gpg SHA256SUMS 2>/dev/null || die "signature does not verify"
  SIGFILE=SHA256SUMS.gpg
fi

PUBLISHED=$(date -u +%FT%TZ)
BASE="https://$ACCOUNT.blob.core.windows.net/$CONTAINER"
cat > latest.json <<EOF2
{
  "name": "Quotient Mainframe OS",
  "version": "$VERSION",
  "channel": "$CHANNEL",
  "package": "$PACKAGE",
  "published": "$PUBLISHED",
  "iso": { "url": "$BASE/$VERSION/$NAME", "file": "$NAME", "size": $SIZE, "sha256": "$SHA" },
  "checksums": { "url": "$BASE/$VERSION/SHA256SUMS", "signature": "$BASE/$VERSION/SHA256SUMS.gpg" },
  "release": "https://github.com/$REPO/releases/tag/v$VERSION"
}
EOF2

if [ "$UPLOAD" = 1 ]; then
  [ -n "$KEY" ] || die "no storage key (--key or AZURE_STORAGE_KEY)"
  command -v az >/dev/null || die "az is not installed"
  log "Uploading to $BASE/$VERSION/"
  az storage container create --name "$CONTAINER" --public-access blob \
    --account-name "$ACCOUNT" --account-key "$KEY" --only-show-errors >/dev/null
  for f in "$NAME" SHA256SUMS $SIGFILE; do
    [ -e "$f" ] || continue
    case "$f" in *.iso) CT=application/octet-stream ;; *.gpg) CT=application/pgp-signature ;; *) CT="text/plain; charset=utf-8" ;; esac
    az storage blob upload --file "$f" --name "$VERSION/$f" --container-name "$CONTAINER" \
      --account-name "$ACCOUNT" --account-key "$KEY" --content-type "$CT" \
      --content-cache-control "public, max-age=31536000, immutable" --overwrite --only-show-errors >/dev/null
  done
  # Only the stable channel moves the pointer the download page reads.
  if [ "$CHANNEL" = stable ]; then
    az storage blob upload --file latest.json --name latest.json --container-name "$CONTAINER" \
      --account-name "$ACCOUNT" --account-key "$KEY" --content-type "application/json" \
      --content-cache-control "public, max-age=300" --overwrite --only-show-errors >/dev/null
  else
    az storage blob upload --file latest.json --name "latest-$CHANNEL.json" --container-name "$CONTAINER" \
      --account-name "$ACCOUNT" --account-key "$KEY" --content-type "application/json" \
      --content-cache-control "public, max-age=300" --overwrite --only-show-errors >/dev/null
  fi
  log "ISO: $BASE/$VERSION/$NAME"
fi

if [ "$RELEASE" = 1 ]; then
  command -v gh >/dev/null || die "gh is not installed"
  TAG="v$VERSION"; [ "$CHANNEL" = stable ] || TAG="v$VERSION-$CHANNEL"
  log "GitHub Release $TAG"
  NOTES=$(printf 'Quotient Mainframe OS %s (%s channel, installs quotient-server-tools %s).\n\nISO: %s\nsha256: `%s`\n\nVerify: `gpg --verify SHA256SUMS.gpg SHA256SUMS && sha256sum -c SHA256SUMS` with the Quotient APT key `%s`.\n' \
    "$VERSION" "$CHANNEL" "$PACKAGE" "$BASE/$VERSION/$NAME" "$SHA" "$REPO_KEY_FPR")
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" SHA256SUMS $SIGFILE latest.json --clobber --repo "$REPO" >/dev/null
  else
    PRE=(); [ "$CHANNEL" = stable ] || PRE=(--prerelease)
    gh release create "$TAG" SHA256SUMS $SIGFILE latest.json --repo "$REPO" \
      --title "Quotient Mainframe OS $VERSION" --notes "$NOTES" "${PRE[@]}" >/dev/null
  fi
fi
log "Published $VERSION ($CHANNEL): sha256 $SHA"
cat latest.json
