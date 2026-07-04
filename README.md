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
zig build # build the kernel image + user module bundle (zig-out/bin)
zig build qemu # boot the full system under QEMU virt (interactive; quit with Ctrl-A x)
zig build qemu-bare # boot the kernel alone; halts after initialization
zig build qemu-debug # boot halted with a gdb stub on :1234
zig build test # run the host unit tests for the arch-independent core
```

`zig build qemu` boots, discovers the machine from the device tree, logs each subsystem
as it comes up (memory, interrupts, objects and scheduler), then hands off to Flint.
Flint loads bundled ELF programs for the name service, console driver, Marble (the
interactive shell), and utilities (`echo`, `cat`, `help`, `cat-via-name`). Type `exit` at
the `marble [/] >` prompt to watch the supervisor restart Marble; quit QEMU with `Ctrl-A`
then `x`. `scripts/m6.sh` drives Marble over serial.

## Layout

Assembly and Zig never share a directory: each arch keeps its non-Zig toolchain
inputs (`.S` sources and the linker script) in an `asm/` subdirectory, so the
arch directory itself is Zig-only.

```
build.zig                 kernel + user ELFs + bundle/flatten tools + QEMU run steps
tools/flatten.zig         host tool: ELF -> load-faithful flat image
tools/bundle.zig          host tool: user module bundle packer
kernel/
  main.zig                post-arch entry; machine discovery; subsystem init; hand-off
  config.zig              compile-time tunables
  error.zig               shared Error set + ABI mapping
  types.zig               arch-free address types
  tests.zig               host unit-test aggregator
  arch/
    arch.zig              the architecture boundary
    host.zig              host-test stand-in for the boundary
    aarch64/
      asm/
        start.S           early boot: EL1, stack, BSS, vectors, MMU enable
        vectors.S         exception vector table
        switch.S          context switch + fresh-thread trampoline
        linker.ld         image layout
      boot.zig            bridge from start.S into Zig
      mmu.zig             seed map, MMU enable, page-table surface
      trap.zig            trap entry: IRQ -> scheduler tick; else diagnose + halt
      cpu.zig             core id, barriers, interrupt mask, halt
      context.zig         thread context: init + switch surface
      gic.zig             GICv2 distributor + CPU interface
      timer.zig           ARM generic timer: monotonic time + deadline
    board/virt.zig        board fallback constants (UART, GIC windows)
  boot/
    dtb.zig               device-tree parse: memory, cores, intctrl windows
    bundle.zig            Flint-module lookup inside the initrd bundle
  memory/
    frames.zig            buddy physical-frame allocator
    slab.zig              per-type object caches
    region.zig            Region: a run of RAM frames
    address_space.zig     AddressSpace: page tables, map/unmap/activate
  object/
    object.zig            common object header (kind + refcount)
    process.zig           Process: AddressSpace + HandleTable + threads
    thread.zig            Thread: context, state, scheduling
  cap/
    handle.zig            Handle {index, generation}
    handle_table.zig      per-process handle table
  sched/
    runqueue.zig          intrusive per-core queues
    scheduler.zig         MLFQ + driver class, tick, demote/boost, yield
  debug/
    console.zig           panic-only PL011 UART
    panic.zig             panic diagnostic + halt
user/
  flint/main.zig          boot supervisor; spawns servers and Marble
  marble/main.zig         interactive shell
  lib/
    root.zig              user runtime entry; re-exports submodules
    cap/                  handle indices and grant layouts
    ipc/                  message envelope and protocol constants
    syscall/              syscall wrappers
    runtime/              program entry and init-message handling
    io/                   streams and formatting helpers
    boot/                 bundle reader, ELF loader, DTB parser
    shell/                Marble help/about catalog
    mem/                  user-space memory helpers
  programs/common/        bundled utilities (echo, cat, help, …)
  drivers/console/        PL011 console driver
  servers/naming/         name service
```
