// aarch64 early entry: bring up one core at EL1, install a stack and vectors, zero BSS, then call into Zig.

.section .text.boot
.global _start

// ARM64 Linux Image header: makes QEMU load us correctly and hand the DTB in x0; code0 branches over it to _start.

_image_header:

    b       _start              // code0: executable entry, branches past header
    .long   0                   // code1
    .quad   0x80000             // text_offset: load at RAM base + 0x80000
    .quad   __image_size        // image_size: total footprint incl. BSS + stack
    .quad   0                   // flags: little-endian, 4 KiB pages
    .quad   0                   // res2
    .quad   0                   // res3
    .quad   0                   // res4
    .ascii  "ARM\x64"           // magic at offset 56
    .long   0                   // res5

_start:

    // Secondary cores are parked for M0; only affinity 0 proceeds (later milestones bring them up via PSCI).

    mrs     x1, mpidr_el1
    and     x1, x1, #0xff
    cbnz    x1, park_secondary

    // QEMU may enter at EL2 when virtualization is on; drop to EL1 so the whole kernel runs at one known level.

    mrs     x1, CurrentEL
    lsr     x1, x1, #2
    cmp     x1, #2
    b.ne    at_el1
    bl      drop_to_el1

at_el1:

    // Permit EL1/EL0 use of the FP/SIMD unit so compiler-emitted NEON does not trap (CPACR_EL1.FPEN = 0b11).

    mov     x1, #(3 << 20)
    msr     cpacr_el1, x1
    isb

    // Install the boot stack; the MMU is off, so this physical address is also its virtual address.

    adrp    x1, __boot_stack_top
    add     x1, x1, :lo12:__boot_stack_top
    mov     sp, x1

    // Point the exception base at our vector table before anything can fault.

    adrp    x1, vector_table
    add     x1, x1, :lo12:vector_table
    msr     vbar_el1, x1
    isb

    // Zero the BSS so every Zig static starts defined.

    adrp    x2, __bss_start
    add     x2, x2, :lo12:__bss_start
    adrp    x3, __bss_end
    add     x3, x3, :lo12:__bss_end

zero_bss:
    cmp     x2, x3
    b.hs    enter_zig
    str     xzr, [x2], #8
    b       zero_bss

enter_zig:

    // x0 still carries the DTB pointer from firmware.

    bl      kernel_boot

    // kernel_boot is noreturn; this only guards against a stray return.

hang:

    wfe
    b       hang

park_secondary:

    wfe
    b       park_secondary

drop_to_el1:

    // Drop from EL2 to EL1h, returning (via eret) to this routine's caller.

    mov     x2, #(1 << 31)      // HCR_EL2.RW: EL1 executes in AArch64
    msr     hcr_el2, x2
    mov     x2, #0x3c5          // resume at EL1h with D/A/I/F masked
    msr     spsr_el2, x2
    msr     elr_el2, x30
    eret
