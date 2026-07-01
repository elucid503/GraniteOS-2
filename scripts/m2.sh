#!/usr/bin/env bash

# M2 test: boot under QEMU and check the "Done when" over serial - two kernel-mode threads
# time-slice on one core under the timer, demote/boost correctly, and yield works. The host
# unit tests (scheduler, handle table, runqueue) are run separately by `zig build test`.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

output="$(zig build qemu -Dtest=true 2>&1)"
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

check "memory foundation intact"    "M1: OK no leaks"
check "scheduler brought up"        "M2: scheduler up; two threads admitted."
check "threads time-slice"          "M2: time-slice OK"
check "yield works"                 "M2: yield OK"
check "quantum exhaustion demotes"  "M2: demote OK"
check "periodic boost restores"     "M2: boost OK"
check "milestone complete"          "M2: OK objects and scheduler up"

# Global exit

if [ "$fail" -ne 0 ]; then

    echo "M2: FAIL"
    exit 1

fi

echo "M2: PASS"
