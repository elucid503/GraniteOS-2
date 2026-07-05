#!/usr/bin/env bash

# M8 smoke test: the system is stable on the discovered core count - whatever it is - and a
# thread-stress program runs to completion alongside a working shell (08-roadmap.md M8 "Done when").

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

# Input is fed one line at a time with pauses: QEMU's Windows stdio chardev drops any burst past the
# serial mux buffer (~33 bytes), so a whole session piped at once gets truncated before the guest runs.

feed() {

    sleep 5

    for line in "$@"; do

        printf '%s\n' "$line"
        sleep 8

    done

}

boot() {

    local cores="$1"
    shift

    feed "$@" | timeout 90 qemu-system-aarch64 \
        -machine virt -cpu cortex-a57 -smp "$cores" -m 256M -nographic \
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

# GICv2 tops out at 8 cores on `virt`; the point is that no count is special-cased.

for cores in 1 2 4 8; do

    echo "--- $cores core(s) ---"

    output="$(boot "$cores" 'stress 8' 'stress 8' 'echo still-works')"

    echo "$output"

    if [ "$cores" -eq 1 ]; then

        check "all cores online"       "$output" "SMP: 1 core online ... Loaded"

    else

        check "all cores online"       "$output" "SMP: $cores cores online ... Loaded"

    fi

    check "machine reports the count"  "$output" "Machine: $cores core"
    check "stress run completed"       "$output" "stress: 8 workers done"
    check "shell still responsive"     "$output" "still-works"

    if grep -qF -- "KERNEL PANIC" <<<"$output"; then

        echo "  FAIL - kernel panicked"
        fail=1

    else

        echo "  ok   - no panic"

    fi

done

if [ "$fail" -ne 0 ]; then

    echo "m8: FAIL"
    exit 1

fi

echo "m8: PASS"
