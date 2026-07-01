// The context switch: save the callee-saved frame into *x0, restore it from *x1, and return on the restored link register. Offsets match `context.Context`: sp 0, x19..x28 8, x29 88, x30 96.

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

    ldp     x2,  x19, [x1, #0]
    ldp     x20, x21, [x1, #16]
    ldp     x22, x23, [x1, #32]
    ldp     x24, x25, [x1, #48]
    ldp     x26, x27, [x1, #64]
    ldp     x28, x29, [x1, #80]
    ldr     x30,      [x1, #96]
    mov     sp, x2

    ret

// A fresh thread's first switch-in lands here (context.init_thread_context put the entry in x19, the argument in x20). Preemption switched in with IRQs masked, so unmask before entering the thread.

.global thread_trampoline

thread_trampoline:

    msr     daifclr, #2
    mov     x0, x20
    blr     x19

    // The thread's entry function returned: retire it through the scheduler.

    bl      kernel_thread_return

    // kernel_thread_return is noreturn; guard anyway.

1:

    wfe
    b       1b
