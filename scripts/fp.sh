#!/usr/bin/env bash

# Lazy FP/SIMD smoke test (Stage 1.1): two-plus threads grind concurrent double-precision NEON arithmetic and the
# `neon` program checks every worker reproduced the single-threaded golden checksum bit-for-bit. A context switch that
# dropped or aliased a thread's vector file would diverge one worker and fail the match. Runs across a few core counts
# so the cross-core FP save/restore handshake is exercised too.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

# Input is fed one line at a time with pauses: QEMU's Windows stdio chardev drops any burst past the serial mux buffer (~33 bytes).

feed() {

    sleep 5

    for line in "$@"; do

        printf '%s\n' "$line"
        sleep 10

    done

}

boot() {

    local cores="$1"
    shift

    feed "$@" | timeout 90 qemu-system-aarch64 \
        -machine virt,gic-version=3 -cpu cortex-a57 -smp "$cores" -m 256M -nographic \
        -kernel zig-out/bin/granite-kernel.bin \
        -initrd zig-out/bin/bundle.img \
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

for cores in 1 2 4; do

    echo "--- $cores core(s) ---"

    output="$(boot "$cores" 'neon 8' 'echo still-works')"

    echo "$output"

    check "all workers matched golden" "$output" "neon: 8 workers ok"
    check "shell still responsive"     "$output" "still-works"

    if grep -qF -- "neon: FAIL" <<<"$output"; then

        echo "  FAIL - a worker's FP state was corrupted across a switch"
        fail=1

    fi

    if grep -qF -- "KERNEL PANIC" <<<"$output"; then

        echo "  FAIL - kernel panicked"
        fail=1

    else

        echo "  ok   - no panic"

    fi

done

if [ "$fail" -ne 0 ]; then

    echo "fp: FAIL"
    exit 1

fi

echo "fp: PASS"
