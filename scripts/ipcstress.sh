#!/usr/bin/env bash

# Stage 2 smoke: independent endpoint queues, handle-transferring calls, replies, and notification signals contend
# across four cores. Every QEMU boot is bounded so a locking regression becomes a failure instead of a hung script.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

feed() {

    sleep 5
    printf '%s\n' 'ipcstress'
    sleep 20
    printf '%s\n' 'echo still-works'

}

output="$(feed | timeout 60 qemu-system-aarch64 \
    -machine virt,gic-version=3 -cpu cortex-a57 -smp 4 -m 256M -nographic \
    -kernel zig-out/bin/granite-kernel.bin \
    -initrd zig-out/bin/bundle.img \
    2>&1 || true)"

echo "$output"

grep -qF -- 'ipcstress: 1600 calls ok' <<<"$output"
grep -qF -- 'still-works' <<<"$output"
! grep -qF -- 'ipcstress: FAIL' <<<"$output"
! grep -qF -- 'KERNEL PANIC' <<<"$output"

echo 'ipcstress: PASS'
