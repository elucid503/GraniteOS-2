#!/usr/bin/env bash

# M7 smoke test: files created in one boot persist across a reboot, and the system still reaches a usable shell
# with the disk absent (08-roadmap.md M7 "Done when").

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

zig build 2>&1

disk="$root/zig-out/m7-disk.img"

rm -f "$disk"

boot() {

    local session="$1"
    shift

    printf '%s' "$session" | timeout 45 qemu-system-aarch64 \
        -machine virt -cpu cortex-a57 -smp 1 -m 256M -nographic \
        -kernel zig-out/bin/granite-kernel.bin \
        -initrd zig-out/bin/bundle.img \
        "$@" 2>&1 || true

}

with_disk=(-drive "if=none,format=raw,id=granite-disk,file=$disk" -device "virtio-blk-device,drive=granite-disk")

fail=0

check() {

    if grep -qF -- "$3" <<<"$2"; then

        echo "  ok   - $1"

    else

        echo "  FAIL - $1 (expected: $3)"
        fail=1

    fi

}

# Boot 1: a fresh disk is formatted; files and directories are created and read back.

qemu-img create -f raw "$disk" 64M >/dev/null 2>&1 || dd if=/dev/zero of="$disk" bs=1M count=64 status=none

session_one=$'mkdir /docs\nwrite /docs/notes persist-me\necho pipe-write | write /docs/piped\nls /\nls /docs\nview /docs/notes\nview /docs/piped\n'
first="$(boot "$session_one" "${with_disk[@]}")"

echo "$first"

check "block driver came up"           "$first" "Block: virtio-blk driver ... Loaded"
check "fresh disk was formatted"       "$first" "Filesystem: formatted fresh Strata volume"
check "directory listed in root"       "$first" "docs/"
check "file created via arguments"     "$first" "notes"
check "file content read back"         "$first" "persist-me"
check "pipeline into write worked"     "$first" "pipe-write"

# Boot 2: the same disk mounts (no reformat) and the files are still there.

session_two=$'view /docs/notes\nls /docs\ndelete /docs/piped\nls /docs\n'
second="$(boot "$session_two" "${with_disk[@]}")"

echo "$second"

check "existing volume mounted"        "$second" "Filesystem: Strata volume mounted"
check "file persisted across reboot"   "$second" "persist-me"

if grep -qF -- "formatted fresh" <<<"$second"; then

    echo "  FAIL - second boot reformatted the disk"
    fail=1

else

    echo "  ok   - second boot did not reformat"

fi

# Boot 3: no disk at all - the filesystem reports unavailable and the shell still works.

session_three=$'ls /\necho still-works\n'
third="$(boot "$session_three")"

echo "$third"

check "filesystem reported unavailable" "$third" "Filesystem: no disk present"
check "ls degrades gracefully"          "$third" "ls: filesystem unavailable"
check "shell still usable"              "$third" "still-works"

rm -f "$disk"

if [ "$fail" -ne 0 ]; then

    echo "m7: FAIL"
    exit 1

fi

echo "m7: PASS"
