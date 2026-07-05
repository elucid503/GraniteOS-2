#!/usr/bin/env bash

# Boot test: boot the bundled user-space system, launch programs from Marble, run a pipeline, and exercise the name
# service over serial.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

session=$'help\necho hello\necho pipe-me | cat\nexit\n'

output="$(printf '%s' "$session" | timeout 30 qemu-system-aarch64 \
    -machine virt -cpu cortex-a57 -smp 1 -m 256M -nographic \
    -kernel zig-out/bin/granite-kernel.bin \
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

check "kernel initialized"            "Flint: hand-off ... Loaded"
check "console driver came up"        "Console: PL011 driver ... Loaded"
check "marble reached prompt"          "marble [/] >"
check "external echo launched"        "hello"
check "pipeline produced output"      "pipe-me"
check "help lists programs"           "GraniteOS - Available Programs"
check "supervisor restart path"       "Exiting MARBLE..."

if [ "$fail" -ne 0 ]; then

    echo "boot: FAIL"
    exit 1

fi

echo "boot: PASS"
