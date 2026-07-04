#!/usr/bin/env bash

# M6 test: boot the bundled user-space system, launch programs from the shell, run a pipeline, and exercise the name
# service over serial.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

session=$'help\necho hello\necho pipe-me | cat\ncat-via-name\nexit\n'

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

check "console driver came up"        "console: driver up"
check "shell reached prompt"          "GraniteOS shell"
check "external echo launched"        "hello"
check "pipeline produced output"      "pipe-me"
check "pipeline exit collection"      "[done] echo=0 cat=0"
check "name service lookup works"     "cat-via-name: resolved console"
check "supervisor restart path"       "bye - the supervisor will bring the shell back."

if [ "$fail" -ne 0 ]; then

    echo "M6: FAIL"
    exit 1

fi

echo "M6: PASS"
