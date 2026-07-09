#!/usr/bin/env bash

# M10 smoke test: boot the x86_64 serial shell path under QEMU q35 and reach Marble.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build -Darch=x86_64 2>&1

session=$'help\necho hello\nexit\n'

# Multiboot1 AOUT-kludge image produced by mbwrap for QEMU `-kernel`.
kernel_img="$(ls zig-out/bin/granite-kernel.mb 2>/dev/null || true)"
if [ -z "$kernel_img" ]; then
    # Fall back to the run-step output under the zig cache if install did not copy it.
    kernel_img="$(find .zig-cache -name 'granite-kernel.mb' 2>/dev/null | head -n1)"
fi
if [ -z "$kernel_img" ]; then
    echo "missing granite-kernel.mb"
    exit 1
fi

output="$(printf '%s' "$session" | timeout 45 qemu-system-x86_64 \
    -machine q35 -cpu qemu64 -smp 1 -m 256M -nographic \
    -kernel "$kernel_img" \
    -initrd zig-out/bin/bundle.img 2>&1 || true)"

echo "$output"

fail=0

check() {

    if grep -qF -- "$2" <<<"$output"; then

        echo "  ok   - $1"

    else

        echo "  FAIL - $1 (expected: $2)"
        fail=1

    fi

}

check "kernel banner"                 "GraniteOS-2 (x86_64 pc)"
check "kernel initialized"            "Flint: hand-off ... Loaded"
check "console driver came up"        "Console: 16550 driver ... Loaded"
check "marble reached prompt"          "marble [/] >"
check "external echo launched"        "hello"
check "help lists programs"           "GraniteOS - Available Programs"

if [ "$fail" -ne 0 ]; then

    echo "boot: FAIL"
    exit 1

fi

echo "boot: PASS"
