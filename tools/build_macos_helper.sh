#!/usr/bin/env bash
# Builds the proxy-only macOS helper from the shared Go host source.
#
# Usage: tools/build_macos_helper.sh <kernel-checkout> [out] [arch]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL="${1:-${JJBOX_KERNEL:-}}"
OUT="${2:-$ROOT/build/macos_helper/jjbox-core-helper}"
ARCH="${3:-arm64}"
TAGS="libbox,with_quic,with_wireguard,with_utls,with_clash_api"

if [[ -z "$KERNEL" || ! -d "$KERNEL/experimental/libbox" ]]; then
  echo "usage: $0 <kernel-checkout-with-experimental/libbox> [out] [arch]" >&2
  exit 2
fi
KERNEL="$(cd "$KERNEL" && pwd)"

WORK="$ROOT/build/macos_helper_src"
rm -rf "$WORK"
mkdir -p "$WORK" "$(dirname "$OUT")"
for file in "$ROOT"/windows/core_host/*.go; do
  case "$file" in
    *_test.go) continue ;;
  esac
  cp "$file" "$WORK/"
done

{
  echo "module github.com/piggycat/jiejiebox/corehost"
  echo
  echo "go 1.25.5"
  echo
  echo "require github.com/sagernet/sing-box v0.0.0"
  echo "require golang.org/x/sys v0.49.0"
  echo
  echo "replace github.com/sagernet/sing-box => $KERNEL"
  grep '^replace ' "$KERNEL/go.mod" || true
} > "$WORK/go.mod"

cd "$WORK"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=mod
export CGO_ENABLED=0
export GOOS=darwin
export GOARCH="$ARCH"
go build -trimpath -buildvcs=false -tags "$TAGS" -o "$OUT" .
echo "built: $OUT"
echo "kernel: $KERNEL @ $(git -C "$KERNEL" rev-parse HEAD)"
