// aarch64 exception vectors: 16 entries (0x80 apart, table 2 KiB aligned), all routed to one diagnose-and-halt path for M0.

.macro VECTOR
.balign 0x80
    b       trap_common
.endm

.section .text.vectors
.balign 2048
.global vector_table

vector_table:

    VECTOR                  // Current EL with SP_EL0: synchronous
    VECTOR                  // Current EL with SP_EL0: IRQ
    VECTOR                  // Current EL with SP_EL0: FIQ
    VECTOR                  // Current EL with SP_EL0: SError

    VECTOR                  // Current EL with SP_ELx: synchronous
    VECTOR                  // Current EL with SP_ELx: IRQ
    VECTOR                  // Current EL with SP_ELx: FIQ
    VECTOR                  // Current EL with SP_ELx: SError

    VECTOR                  // Lower EL, AArch64: synchronous
    VECTOR                  // Lower EL, AArch64: IRQ
    VECTOR                  // Lower EL, AArch64: FIQ
    VECTOR                  // Lower EL, AArch64: SError

    VECTOR                  // Lower EL, AArch32: synchronous
    VECTOR                  // Lower EL, AArch32: IRQ
    VECTOR                  // Lower EL, AArch32: FIQ
    VECTOR                  // Lower EL, AArch32: SError

// Build the 36-word frame that `trap.TrapFrame` describes (x0..x30, pad, ELR, SPSR, ESR, FAR) and call kernel_trap.

.section .text

trap_common:

    sub     sp, sp, #(36 * 8)
    stp     x0, x1,   [sp, #(16 * 0)]
    stp     x2, x3,   [sp, #(16 * 1)]
    stp     x4, x5,   [sp, #(16 * 2)]
    stp     x6, x7,   [sp, #(16 * 3)]
    stp     x8, x9,   [sp, #(16 * 4)]
    stp     x10, x11, [sp, #(16 * 5)]
    stp     x12, x13, [sp, #(16 * 6)]
    stp     x14, x15, [sp, #(16 * 7)]
    stp     x16, x17, [sp, #(16 * 8)]
    stp     x18, x19, [sp, #(16 * 9)]
    stp     x20, x21, [sp, #(16 * 10)]
    stp     x22, x23, [sp, #(16 * 11)]
    stp     x24, x25, [sp, #(16 * 12)]
    stp     x26, x27, [sp, #(16 * 13)]
    stp     x28, x29, [sp, #(16 * 14)]
    str     x30,      [sp, #(30 * 8)]

    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    mrs     x2, esr_el1
    mrs     x3, far_el1
    stp     x0, x1,   [sp, #(32 * 8)]
    stp     x2, x3,   [sp, #(34 * 8)]

    mov     x0, sp
    bl      kernel_trap

    // kernel_trap is noreturn; guard anyway.

1:

    wfe
    b       1b
