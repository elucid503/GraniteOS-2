#!/usr/bin/env bash

# M4 test: boot the full system and check the "Done when" over serial - booting reaches an interactive prompt, typing
# echoes through the console driver, and a builtin runs. Unlike M1-M3/M5, this is the walking skeleton itself: it needs
# the initrd (the Startup Binary), and the shell is interactive (it blocks for input). So we feed a short session over
# serial and bound the run with a timeout, then check the captured log. The console echo is proven by the typed line
# appearing after the prompt; the builtins by their output.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Build the kernel + module bundle, then drive the interactive system directly under QEMU.

zig build 2>&1

session=$'help\nabout\n'

output="$(printf '%s' "$session" | timeout 20 qemu-system-aarch64 \
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

check "hand-off to user space"        "M4: hand-off complete"
check "console driver came up"        "console: driver up"
check "reached the interactive prompt" "GraniteOS shell"
check "typing echoes through driver"  "granite> help"
check "help builtin ran"              "builtins:"
check "about builtin ran"             "bundled ELF programs"

# Global exit

if [ "$fail" -ne 0 ]; then

    echo "M4: FAIL"
    exit 1

fi

echo "M4: PASS"
