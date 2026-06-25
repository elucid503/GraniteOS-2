#!/usr/bin/env bash
# M0 test: boot under QEMU and check the "Done when" over serial — banner, then a deliberate fault diagnostic, then halt.

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

check "banner over serial"   "GraniteOS-2 (aarch64 virt)"
check "panic header"         "*** KERNEL PANIC ***"
check "data-abort syndrome"  "ESR_EL1  = 0x0000000096000044"
check "faulting address"     "FAR_EL1  = 0x0000ffffdead0000"
check "halt"                 "halted."

# Global exit

if [ "$fail" -ne 0 ]; then

    echo "M0: FAIL"
    exit 1

fi

echo "M0: PASS"
