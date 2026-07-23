#!/usr/bin/env bash

# Builds GraniteOS images (if needed) and produces GraniteOS.exe with them embedded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$LAUNCHER/internal/assets/files"
OUT_BIN="$ROOT/zig-out/bin"

cd "$ROOT"

if [[ ! -f "$OUT_BIN/granite-kernel.bin" || ! -f "$OUT_BIN/bundle.img" ]]; then

    echo "Building GraniteOS images (zig build -Ddisk=256)..."
    zig build -Ddisk=256

fi

cp "$OUT_BIN/granite-kernel.bin" "$ASSETS/"
cp "$OUT_BIN/bundle.img" "$ASSETS/"

cd "$LAUNCHER"

go mod tidy
go build -ldflags "-H windowsgui -s -w" -o GraniteOS.exe .

echo "Built $LAUNCHER/GraniteOS.exe"
