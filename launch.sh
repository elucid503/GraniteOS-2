#!/usr/bin/env bash
set -euo pipefail

# Simple launcher for QEMU. This script is intended to be run from the root of the GraniteOS source tree.

cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
usage: ./launch.sh [mode]

modes:
  (none)   serial console, disk + initrd (zig build qemu)
  gui      virtio display + input + audio (zig build qemu-gui)
  debug    gdb stub on :1234, halted at start (zig build qemu-debug)
  nodisk   no persistent disk (zig build qemu-nodisk)
  bare     kernel only, no initrd (zig build qemu-bare)
EOF
}

case "${1:-}" in

    ""|serial) STEP=qemu;        GUI=0; WANT_DISK=1; WANT_INITRD=1; DEBUG=0; NET=1 ;;
    gui)       STEP=qemu-gui;    GUI=1; WANT_DISK=1; WANT_INITRD=1; DEBUG=0; NET=1 ;;
    debug)     STEP=qemu-debug;  GUI=0; WANT_DISK=1; WANT_INITRD=1; DEBUG=1; NET=1 ;;
    nodisk)    STEP=qemu-nodisk; GUI=0; WANT_DISK=0; WANT_INITRD=1; DEBUG=0; NET=1 ;;
    bare)      STEP=qemu-bare;   GUI=0; WANT_DISK=0; WANT_INITRD=0; DEBUG=0; NET=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown mode: $1" >&2; usage; exit 1 ;;

esac

if [[ ! -d zig-out ]]; then

    zig build

fi

# seedisk only runs as a zig build dependency; delegate the first disk launch.
if [[ $WANT_DISK -eq 1 && ! -f disk.img ]]; then

    exec zig build "$STEP"

fi

KERNEL=zig-out/bin/granite-kernel.bin
BUNDLE=zig-out/bin/bundle.img

if [[ ! -f $KERNEL ]]; then

    echo "missing $KERNEL — run zig build" >&2
    exit 1

fi

if [[ $WANT_INITRD -eq 1 && ! -f $BUNDLE ]]; then

    echo "missing $BUNDLE — run zig build" >&2
    exit 1

fi

args=(

    -machine virt,gic-version=3
    -cpu cortex-a57
    -smp 4
    -m 512M
    -global virtio-mmio.force-legacy=false
    -device virtio-rng-device

)

if [[ $NET -eq 1 ]]; then

    args+=(
        -netdev user,id=granite-net,hostfwd=tcp::5555-:5555
        -device virtio-net-device,netdev=granite-net
    )

fi

if [[ $GUI -eq 1 ]]; then

    args+=(

        -display sdl
        -device virtio-gpu-device
        -device virtio-keyboard-device
        -device virtio-tablet-device

    )

    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || "${OS:-}" == Windows_NT ]]; then

        args+=(-audiodev dsound,id=granite-audio)

    else

        args+=(-audiodev sdl,id=granite-audio)

    fi

    args+=(

        -device virtio-sound-device,audiodev=granite-audio,streams=1
        -serial mon:stdio
    )

else

    args+=(-nographic)

fi

if [[ $DEBUG -eq 1 ]]; then

    args+=(-s -S)

fi

args+=(-kernel "$KERNEL")

if [[ $WANT_INITRD -eq 1 ]]; then

    args+=(-initrd "$BUNDLE")

fi

if [[ $WANT_DISK -eq 1 ]]; then

    args+=(

        -drive if=none,format=raw,id=granite-disk,file=disk.img
        -device virtio-blk-device,drive=granite-disk

    )

fi

if [[ $GUI -eq 1 ]]; then

    qemu-system-aarch64 "${args[@]}" || true

else

    exec qemu-system-aarch64 "${args[@]}"

fi
