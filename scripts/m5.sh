#!/usr/bin/env bash

# M5 test: boot the kernel (no initrd) and check the "Done when" over serial - a single thread waits on an endpoint
# and a notification at once (multi-wait), and a client blocked in `call` wakes with `Gone` when its server dies
# without replying. The bare kernel halts after the M5 demo, so this runs unattended and exits via semihosting. The
# fault-teardown and multi-wait mechanisms also carry `zig build test` host coverage (kernel/ipc/transfer.zig).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

output="$(zig build qemu-bare -Dtest=true 2>&1)"
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

check "scheduler still up"            "M2: OK objects and scheduler up"
check "IPC spine still up"            "M3: OK syscalls and IPC spine up"
check "multi-wait on one thread"      "M5: multi-wait OK"
check "dead server wakes clients"     "M5: gone OK"
check "milestone complete"            "M5: OK robustness and multi-wait up"

# Global exit

if [ "$fail" -ne 0 ]; then

    echo "M5: FAIL"
    exit 1

fi

echo "M5: PASS"
