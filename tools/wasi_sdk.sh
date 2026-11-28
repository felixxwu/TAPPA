#!/usr/bin/env bash
# Downloads the pinned wasi-sdk into build/wasi-sdk (once), checks its SHA-256, prints its path.
set -euo pipefail
cd "$(dirname "$0")/.."

VER=25
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  PLAT=x86_64-linux;  SHA=52640dde13599bf127a95499e61d6d640256119456d1af8897ab6725bcf3d89c ;;
  Linux-aarch64) PLAT=arm64-linux;   SHA=47fccad8b2498f2239e05e1115c3ffc652bf37e7de2f88fb64b2d663c976ce2d ;;
  Darwin-arm64)  PLAT=arm64-macos;   SHA=e1e529ea226b1db0b430327809deae9246b580fa3cae32d31c82dfe770233587 ;;
  Darwin-x86_64) PLAT=x86_64-macos;  SHA=55e3ff3fee1a15678a16eeccba0129276c9f6be481bc9c283e7f9f65bf055c11 ;;
  *) echo "no wasi-sdk for $(uname -sm)" >&2; exit 1 ;;
esac

DIR="$PWD/build/wasi-sdk"
if [[ ! -x $DIR/bin/clang ]]; then
  TGZ="wasi-sdk-$VER.0-$PLAT.tar.gz"
  mkdir -p build
  curl -fsSL --retry 5 --retry-all-errors -o "build/$TGZ" "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-$VER/$TGZ" >&2
  echo "$SHA  build/$TGZ" | shasum -a 256 -c - >&2
  rm -rf "$DIR" && mkdir -p "$DIR"
  tar -xzf "build/$TGZ" -C "$DIR" --strip-components=1
  rm "build/$TGZ"
fi
echo "$DIR"
