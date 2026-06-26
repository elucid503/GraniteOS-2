# GraniteOS 2

A from-scratch **microkernel** rewrite of GraniteOS for ARM64 (and, later,
x86_64). The kernel keeps only address spaces, threads & scheduling, IPC,
interrupt dispatch, and capabilities; the filesystem and device drivers become
user-space servers.

## Requirements

- **Zig 0.15**
- **QEMU** with `qemu-system-aarch64`.

## Build and run

```sh
zig build # build the kernel ELF + flat boot image (zig-out/bin)
zig build qemu # boot under QEMU virt (interactive; quit with Ctrl-A x)
zig build qemu-debug # boot halted with a gdb stub on :1234
zig build test # run the host unit tests for the arch-independent core
```

`zig build qemu` boots, discovers the machine from the device tree, brings up the
memory foundation, runs a leak-free alloc/map/free stress loop, then idles; quit
QEMU with `Ctrl-A` then `x`. `scripts/m1.sh` runs that boot unattended and checks
the milestone's exit criteria over serial.

## Layout

Assembly and Zig never share a directory: each arch keeps its non-Zig toolchain
inputs (`.S` sources and the linker script) in an `asm/` subdirectory, so the
arch directory itself is Zig-only.

```
build.zig                 kernel + flatten tool + QEMU run steps
tools/flatten.zig         host tool: ELF -> load-faithful flat image
kernel/
  main.zig                post-arch entry; machine discovery; M1 stress demo
  config.zig              compile-time tunables
  error.zig               shared Error set + ABI mapping
  types.zig               arch-free address types
  tests.zig               host unit-test aggregator
  arch/
    arch.zig              the architecture boundary
    aarch64/
      asm/
        start.S           early boot: EL1, stack, BSS, vectors, MMU enable
        vectors.S         exception vector table
        linker.ld         image layout
      boot.zig            bridge from start.S into Zig
      mmu.zig             seed map, MMU enable, page-table surface
      trap.zig            trap entry (diagnose + halt)
      cpu.zig             core id, barriers, halt
    board/virt.zig        board fallback constants (panic UART base)
  boot/
    dtb.zig               device-tree parse: memory banks + core count
  memory/
    frames.zig            buddy physical-frame allocator
    slab.zig              per-type object caches
    region.zig            Region: a run of RAM frames
    address_space.zig     AddressSpace: page tables, map/unmap/activate
  object/
    object.zig            common object header (kind + refcount)
  debug/
    console.zig           panic-only PL011 UART
    panic.zig             panic diagnostic + halt
```
