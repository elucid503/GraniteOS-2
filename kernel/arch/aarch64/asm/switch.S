// The context switch: save the callee-saved frame into *x0, restore it from *x1, and return on the restored link register. Offsets match `context.Context`: sp 0, x19..x28 8, x29 88, x30 96, sp_el0 104, used_fp 112, fp_v 128, fpcr 640, fpsr 648.

.section .text
.global switch_context

switch_context:

    mov     x2, sp
    stp     x2,  x19, [x0, #0]
    stp     x20, x21, [x0, #16]
    stp     x22, x23, [x0, #32]
    stp     x24, x25, [x0, #48]
    stp     x26, x27, [x0, #64]
    stp     x28, x29, [x0, #80]
    str     x30,      [x0, #96]
    mrs     x3, sp_el0
    str     x3,       [x0, #104]

    ldp     x2,  x19, [x1, #0]
    ldp     x20, x21, [x1, #16]
    ldp     x22, x23, [x1, #32]
    ldp     x24, x25, [x1, #48]
    ldp     x26, x27, [x1, #64]
    ldp     x28, x29, [x1, #80]
    ldr     x30,      [x1, #96]
    ldr     x3,       [x1, #104]
    msr     sp_el0, x3
    mov     sp, x2

    // Lazy FP/SIMD (Stage 1.1): save the outgoing thread's vector file only if it ever trapped into FP, restore the
    // incoming thread's only if it did. A switch into a thread that has not used FP leaves CPACR trapping EL0 FP so
    // its first use faults in through `fp_common`. The kernel itself is built FP-free, so no EL1 code between switches
    // clobbers the live user vector state these paths preserve. This runs at EL1, where FP is always permitted.

    ldr     x4, [x0, #112]              // outgoing used_fp
    cbz     x4, 1f

    add     x5, x0, #128
    stp     q0,  q1,  [x5, #0]
    stp     q2,  q3,  [x5, #32]
    stp     q4,  q5,  [x5, #64]
    stp     q6,  q7,  [x5, #96]
    stp     q8,  q9,  [x5, #128]
    stp     q10, q11, [x5, #160]
    stp     q12, q13, [x5, #192]
    stp     q14, q15, [x5, #224]
    stp     q16, q17, [x5, #256]
    stp     q18, q19, [x5, #288]
    stp     q20, q21, [x5, #320]
    stp     q22, q23, [x5, #352]
    stp     q24, q25, [x5, #384]
    stp     q26, q27, [x5, #416]
    stp     q28, q29, [x5, #448]
    stp     q30, q31, [x5, #480]
    mrs     x6, fpcr
    mrs     x7, fpsr
    add     x8, x0, #640
    stp     x6, x7,   [x8, #0]

1:

    ldr     x4, [x1, #112]             // incoming used_fp
    cbz     x4, 2f

    add     x5, x1, #128
    ldp     q0,  q1,  [x5, #0]
    ldp     q2,  q3,  [x5, #32]
    ldp     q4,  q5,  [x5, #64]
    ldp     q6,  q7,  [x5, #96]
    ldp     q8,  q9,  [x5, #128]
    ldp     q10, q11, [x5, #160]
    ldp     q12, q13, [x5, #192]
    ldp     q14, q15, [x5, #224]
    ldp     q16, q17, [x5, #256]
    ldp     q18, q19, [x5, #288]
    ldp     q20, q21, [x5, #320]
    ldp     q22, q23, [x5, #352]
    ldp     q24, q25, [x5, #384]
    ldp     q26, q27, [x5, #416]
    ldp     q28, q29, [x5, #448]
    ldp     q30, q31, [x5, #480]
    add     x8, x1, #640
    ldp     x6, x7,   [x8, #0]
    msr     fpcr, x6
    msr     fpsr, x7

    mrs     x6, cpacr_el1
    orr     x6, x6, #(3 << 20)         // FPEN=0b11: EL0 may use FP without trapping
    msr     cpacr_el1, x6
    isb
    ret

2:

    mrs     x6, cpacr_el1
    bic     x6, x6, #(3 << 20)
    orr     x6, x6, #(1 << 20)         // FPEN=0b01: trap EL0 FP so the next use faults in
    msr     cpacr_el1, x6
    isb

    ret

// A fresh kernel thread's first switch-in lands here (context.init_thread_context put the entry in x19, the argument
// in x20). Reap any thread that exited to make room, unmask IRQs, then enter the thread at EL1.

.global thread_trampoline

thread_trampoline:

    bl      kernel_after_switch
    msr     daifclr, #2
    mov     x0, x20
    blr     x19

    // The thread's entry function returned: retire it through the scheduler.

    bl      kernel_thread_return

    // kernel_thread_return is noreturn; guard anyway.

1:

    wfe
    b       1b

// A fresh user thread's first switch-in lands here (context.init_user_thread_context put the entry in x19, the user
// stack in x20, the argument in x21). Reap any exited predecessor, then drop to EL0 via eret: SP_EL1 is already the
// thread's kernel stack (loaded by switch_context), SP_EL0 becomes the user stack, and SPSR = EL0t with IRQs unmasked.

.global user_trampoline

user_trampoline:

    bl      kernel_after_switch
    msr     sp_el0, x20
    msr     elr_el1, x19
    msr     spsr_el1, xzr
    mov     x0, x21
    eret
