#!/usr/bin/env bash
# Builds the threaded wasm viewer into build/viewer/ (needs a dated nightly for build-std + atomics).
# Needs: wasm-bindgen-cli at the same version as the crate, and wasi-sdk (tools/wasi_sdk.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

NIGHTLY="${NIGHTLY:-nightly-2026-11-10}" # CI reads this default (grep) so there is one pin
OUT=build/viewer
export WASI_SDK="${WASI_SDK:-$(tools/wasi_sdk.sh)}"
export RUSTFLAGS="--cfg=web_sys_unstable_apis -C target-feature=+atomics,+bulk-memory,+mutable-globals -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=2147483648"

cargo "+$NIGHTLY" build -p app --lib --release --target wasm32-unknown-unknown -Z build-std=std,panic_abort

rm -rf "$OUT"
mkdir -p "$OUT"
wasm-bindgen target/wasm32-unknown-unknown/release/app.wasm --out-dir "$OUT" --out-name viewer --target web
cp web/viewer/index.html "$OUT/index.html"
echo "built $OUT"
