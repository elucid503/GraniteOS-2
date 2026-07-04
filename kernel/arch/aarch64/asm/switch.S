// The context switch: save the callee-saved frame into *x0, restore it from *x1, and return on the restored link register. Offsets match `context.Context`: sp 0, x19..x28 8, x29 88, x30 96, sp_el0 104.

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
