#!/bin/bash
# Extract the stock 64-bit WebView + TrichromeLibrary from a Nothing OS product.img
# into files/product/app/, where make.sh expects them.
#
# These APKs are Google-signed proprietary binaries and are NOT redistributed in
# this repo (also: WebViewGoogle is >100MB, above GitHub's file limit). Pull them
# from your own stock firmware dump.
#
# Usage: scripts/extract_stock_webview.sh /path/to/stock/product.img

set -eo pipefail

PRODUCT_IMG="$1"
if [ -z "$PRODUCT_IMG" ] || [ ! -f "$PRODUCT_IMG" ]; then
  echo "usage: $0 /path/to/stock/product.img" 1>&2
  exit 1
fi

command -v fsck.erofs >/dev/null || { echo "fsck.erofs not found (install erofs-utils)" 1>&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Extracting $PRODUCT_IMG ..."
fsck.erofs --extract="$TMP" --no-preserve "$PRODUCT_IMG" >/dev/null 2>&1

# NOS 4.1 layout: product.img root contains app/ directly
copy_apk() {
  local src="$TMP/app/$1/$1.apk" dst="$REPO/files/product/app/$2/$2.apk"
  [ -f "$src" ] || { echo "missing in image: app/$1/$1.apk" 1>&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  chmod 0644 "$dst"
  echo "  -> $(basename "$dst") ($(du -h "$dst" | cut -f1))"
}

# stock name            -> name used by files/ (arter97's slot names)
copy_apk WebViewGoogle     WebViewGoogle64
copy_apk TrichromeLibrary  TrichromeLibrary64

echo "Done. Verify the WebView lib is 64-bit (must be lib/arm64-v8a/libmonochrome.so):"
unzip -l "$REPO/files/product/app/WebViewGoogle64/WebViewGoogle64.apk" | grep -E 'lib/.*libmonochrome' || true
