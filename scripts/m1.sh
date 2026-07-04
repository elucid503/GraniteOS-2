#!/usr/bin/env bash

# M1 test: boot under QEMU and check the "Done when" over serial - the machine is discovered from the DTB and the
# alloc/map/free stress loop completes with no leaks. The host unit tests are run separately by `zig build test`.

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

check "banner over serial"      "GraniteOS-2 (aarch64 virt)"
check "core count discovered"   "cores "
check "ram bank discovered"     "ram 0x0000000040000000"
check "frame allocator up"      "frames total "
check "stress loop ran"         "M1 stress "
check "no leaks"                "M1: OK no leaks"

# Global exit

if [ "$fail" -ne 0 ]; then

    echo "M1: FAIL"
    exit 1

fi

echo "M1: PASS"
