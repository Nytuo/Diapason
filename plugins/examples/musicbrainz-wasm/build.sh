#!/bin/sh
# Builds plugin.wasm from src/plugin.c with clang (wasm32 target) and wasm-ld.
# Any wasm-ld works; rust-lld from a Rust toolchain does too: WASM_LD="rust-lld -flavor wasm".
set -eu
cd "$(dirname "$0")"
CLANG="${CLANG:-clang}"
WASM_LD="${WASM_LD:-wasm-ld}"
"$CLANG" --target=wasm32 -O2 -nostdlib -ffreestanding -fno-builtin -Wall -c src/plugin.c -o plugin.o
$WASM_LD --no-entry --strip-all -z stack-size=65536 --initial-memory=262144 \
  plugin.o -o plugin.wasm
rm -f plugin.o
echo "built $(pwd)/plugin.wasm"
