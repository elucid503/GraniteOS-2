// aarch64 exception vectors: 16 entries (0x80 apart, table 2 KiB aligned). The kernel-level IRQ slot
// feeds the scheduler tick; everything else is still unexpected and routes to diagnose-and-halt.

.macro VECTOR target
.balign 0x80
    b       \target
.endm

.section .text.vectors
.balign 2048
.global vector_table

vector_table:

    VECTOR trap_common      // Current EL with SP_EL0: synchronous
    VECTOR trap_common      // Current EL with SP_EL0: IRQ
    VECTOR trap_common      // Current EL with SP_EL0: FIQ
    VECTOR trap_common      // Current EL with SP_EL0: SError

    VECTOR trap_common      // Current EL with SP_ELx: synchronous
    VECTOR irq_common       // Current EL with SP_ELx: IRQ
    VECTOR trap_common      // Current EL with SP_ELx: FIQ
    VECTOR trap_common      // Current EL with SP_ELx: SError

    VECTOR svc_common       // Lower EL, AArch64: synchronous (EL0 syscall via svc)
    VECTOR irq_common       // Lower EL, AArch64: IRQ (preempt the user thread)
    VECTOR trap_common      // Lower EL, AArch64: FIQ
    VECTOR trap_common      // Lower EL, AArch64: SError

    VECTOR trap_common      // Lower EL, AArch32: synchronous
    VECTOR trap_common      // Lower EL, AArch32: IRQ
    VECTOR trap_common      // Lower EL, AArch32: FIQ
    VECTOR trap_common      // Lower EL, AArch32: SError

// Kernel-level IRQ: save the caller-saved registers and return state, dispatch, and eret back.
// The callee-saved registers need no slot - kernel_irq preserves them per the AAPCS, and a
// preemptive context switch inside it parks them in the thread's own Context.

.section .text

irq_common:

    sub     sp, sp, #(24 * 8)
    stp     x0, x1,   [sp, #(16 * 0)]
    stp     x2, x3,   [sp, #(16 * 1)]
    stp     x4, x5,   [sp, #(16 * 2)]
    stp     x6, x7,   [sp, #(16 * 3)]
    stp     x8, x9,   [sp, #(16 * 4)]
    stp     x10, x11, [sp, #(16 * 5)]
    stp     x12, x13, [sp, #(16 * 6)]
    stp     x14, x15, [sp, #(16 * 7)]
    stp     x16, x17, [sp, #(16 * 8)]
    stp     x18, x29, [sp, #(16 * 9)]

    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    stp     x30, x0,  [sp, #(16 * 10)]
    str     x1,       [sp, #(16 * 11)]

    bl      kernel_irq

    ldr     x1,       [sp, #(16 * 11)]
    ldp     x30, x0,  [sp, #(16 * 10)]
    msr     elr_el1, x0
    msr     spsr_el1, x1

    ldp     x18, x29, [sp, #(16 * 9)]
    ldp     x16, x17, [sp, #(16 * 8)]
    ldp     x14, x15, [sp, #(16 * 7)]
    ldp     x12, x13, [sp, #(16 * 6)]
    ldp     x10, x11, [sp, #(16 * 5)]
    ldp     x8, x9,   [sp, #(16 * 4)]
    ldp     x6, x7,   [sp, #(16 * 3)]
    ldp     x4, x5,   [sp, #(16 * 2)]
    ldp     x2, x3,   [sp, #(16 * 1)]
    ldp     x0, x1,   [sp, #(16 * 0)]
    add     sp, sp, #(24 * 8)

    eret

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

// EL0 system call: build the frame `trap.SyscallFrame` describes (x0..x30, ELR, SPSR, pad = 34 words), dispatch, and
// return to EL0 via eret. The whole frame is saved and restored so a syscall preserves every user register but x0
// (the result). A blocking syscall context-switches away inside kernel_syscall and later resumes here to eret back.

svc_common:

    sub     sp, sp, #(34 * 8)
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

    mrs     x9, elr_el1
    mrs     x10, spsr_el1
    stp     x9, x10,  [sp, #(31 * 8)]

    mov     x0, sp
    bl      kernel_syscall

    ldp     x9, x10,  [sp, #(31 * 8)]
    msr     elr_el1, x9
    msr     spsr_el1, x10

    ldp     x0, x1,   [sp, #(16 * 0)]
    ldp     x2, x3,   [sp, #(16 * 1)]
    ldp     x4, x5,   [sp, #(16 * 2)]
    ldp     x6, x7,   [sp, #(16 * 3)]
    ldp     x8, x9,   [sp, #(16 * 4)]
    ldp     x10, x11, [sp, #(16 * 5)]
    ldp     x12, x13, [sp, #(16 * 6)]
    ldp     x14, x15, [sp, #(16 * 7)]
    ldp     x16, x17, [sp, #(16 * 8)]
    ldp     x18, x19, [sp, #(16 * 9)]
    ldp     x20, x21, [sp, #(16 * 10)]
    ldp     x22, x23, [sp, #(16 * 11)]
    ldp     x24, x25, [sp, #(16 * 12)]
    ldp     x26, x27, [sp, #(16 * 13)]
    ldp     x28, x29, [sp, #(16 * 14)]
    ldr     x30,      [sp, #(30 * 8)]
    add     sp, sp, #(34 * 8)

    eret
