#!/usr/bin/env bash

# M3 test: boot under QEMU and check the "Done when" over serial - two user-mode processes complete a call/reply
# round-trip over a badged endpoint, the receiver sees the correct badge, a Region handle passes across the message,
# and an IPC micro-benchmark records the round-trip cost. The host unit tests (IPC transfer, handle table, scheduler)
# run separately via `zig build test`.

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

check "scheduler still up"          "M2: OK objects and scheduler up"
check "user processes spawned"      "M3: two user processes spawned"
check "call/reply round-trip"       "M3: call/reply OK"
check "receiver saw the badge"      "M3: badge OK"
check "handle crossed the message"  "M3: handle-passing OK"
check "round-trip benchmarked"      "M3: round-trip "
check "milestone complete"          "M3: OK syscalls and IPC spine up"

# Global exit

if [ "$fail" -ne 0 ]; then

    echo "M3: FAIL"
    exit 1

fi

echo "M3: PASS"
