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
```

`zig build qemu` boots and stays halted in a low-power loop after the demo
fault; quit QEMU with `Ctrl-A` then `x`.

## Layout

Assembly and Zig never share a directory: each arch keeps its non-Zig toolchain
inputs (`.S` sources and the linker script) in an `asm/` subdirectory, so the
arch directory itself is Zig-only.

```
build.zig                 kernel + flatten tool + QEMU run steps
tools/flatten.zig         host tool: ELF -> load-faithful flat image
kernel/
  main.zig                post-arch entry; banner; M0 fault demo
  config.zig              compile-time tunables
  arch/
    arch.zig              the compile-time-selected arch boundary
    aarch64/
      asm/
        start.S           early boot: EL1, stack, BSS, vectors, MMU enable
        vectors.S         exception vector table
        linker.ld         image layout
      boot.zig            bridge from start.S into Zig
      mmu.zig             identity map + MMU enable
      trap.zig            trap entry (M0: diagnose + halt)
      cpu.zig             core id, barriers, halt
    board/virt.zig   board fallback constants (panic UART base)
  debug/
    console.zig           panic-only PL011 UART
    panic.zig             panic diagnostic + halt
```
