#!/usr/bin/env bash

# M9 smoke test: the GUI stack comes up on ramfb + virtio-input hardware and the shell stays responsive
# (08-roadmap.md M9 "Done when").

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

gui_devices=(
    -L pc-bios
    -device ramfb
    -device virtio-keyboard-device
    -device virtio-tablet-device
)

# Input is fed one line at a time with short pauses: QEMU's Windows stdio chardev drops bursts past the serial mux buffer (~33 bytes).

feed() {

    sleep 8

    for line in "$@"; do

        printf '%s\n' "$line"
        sleep 2

    done

}

boot() {

    feed "$@" | timeout 60 qemu-system-aarch64 \
        -machine virt,gic-version=3 -cpu cortex-a57 -smp 4 -m 256M -nographic \
        -kernel zig-out/bin/granite-kernel.bin \
        -initrd zig-out/bin/bundle.img \
        "${gui_devices[@]}" \
        2>&1 || true

}

fail=0

check() {

    if grep -qF -- "$3" <<<"$2"; then

        echo "  ok   - $1"

    else

        echo "  FAIL - $1 (expected: $3)"
        fail=1

    fi

}

echo "--- GUI boot ---"

output="$(boot 'echo still-works')"

echo "$output"

check "display driver loaded"   "$output" "Display: ramfb driver ... Loaded"
check "input server loaded"     "$output" "Input: 2 virtio-input device(s) ... Loaded"
check "compositor loaded"       "$output" "Compositor:"
check "welcome screen presented" "$output" "welcome: presented"
check "shell still responsive"  "$output" "still-works"

if grep -qF -- "KERNEL PANIC" <<<"$output"; then

    echo "  FAIL - kernel panicked"
    fail=1

else

    echo "  ok   - no panic"

fi

if [ "$fail" -ne 0 ]; then

    echo "m9: FAIL"
    exit 1

fi

echo "m9: PASS"