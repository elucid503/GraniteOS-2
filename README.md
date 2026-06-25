# GraniteOS

A from-scratch **microkernel** rewrite of GraniteOS for ARM64 (and, later,
x86_64). The kernel keeps only address spaces, threads & scheduling, IPC,
interrupt dispatch, and capabilities; the filesystem and device drivers become
user-space servers. See [`_docs/`](_docs) for the full design — start with
[the vision](_docs/00-vision-and-decisions.md) and
[the roadmap](_docs/08-roadmap.md).

## Status: M0 — boot stub

The first milestone (`_docs/08-roadmap.md` M0) is complete. The kernel boots on
QEMU `virt`, drops to EL1, parks secondary cores, zeroes BSS, enables the MMU
over an identity mapping, installs exception vectors, and reaches `main`, which
prints a banner over the serial UART. It then triggers a deliberate fault to
prove the trap path: the exception vectors catch it and the panic handler prints
a diagnostic (`ESR`/`ELR`/`FAR`/`SPSR`) before halting.

Everything beyond the debug UART — allocation, scheduling, user mode — is
deferred to later milestones.

## Requirements

- **Zig 0.15** (pinned; the toolchain decision is in `_docs/06-kernel-ddd.md` Section 1).
- **QEMU** with `qemu-system-aarch64`.

## Build and run

```sh
zig build                 # build the kernel ELF + flat boot image (zig-out/bin)
zig build qemu            # boot under QEMU virt (interactive; quit with Ctrl-A x)
zig build qemu-debug      # boot halted with a gdb stub on :1234
```

`zig build qemu` boots and stays halted in a low-power loop after the demo
fault; quit QEMU with `Ctrl-A` then `x`.

### M0 test

`-Dtest=true` builds a variant that exits QEMU (via semihosting) after the demo
fault, so the boot can be checked unattended:

```sh
scripts/m0.sh
```

It checks the M0 "Done when" over serial: the banner appears and the deliberate
fault prints its diagnostic before halting.

## Boot image note

QEMU hands the device-tree pointer to the kernel in `x0` only when it boots a
**flat image** (its Linux boot path), not a bare ELF. A plain
`objcopy`-to-binary drops the page gaps between sections and misaligns
everything, so the flat image is produced by a small host tool
([`tools/flatten.zig`](tools/flatten.zig)) that lays out each load segment
faithfully. The ELF is kept alongside for symbols (gdb, `readelf`).

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
