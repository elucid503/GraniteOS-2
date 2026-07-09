.intel_syntax noprefix

.section .text
.global switch_context

switch_context:

    mov     [rdi + 0], rsp
    mov     [rdi + 8], rbx
    mov     [rdi + 16], rbp
    mov     [rdi + 24], r12
    mov     [rdi + 32], r13
    mov     [rdi + 40], r14
    mov     [rdi + 48], r15

    mov     rsp, [rsi + 0]
    mov     rbx, [rsi + 8]
    mov     rbp, [rsi + 16]
    mov     r12, [rsi + 24]
    mov     r13, [rsi + 32]
    mov     r14, [rsi + 40]
    mov     r15, [rsi + 48]
    ret

.global thread_trampoline

thread_trampoline:

    call    kernel_after_switch
    sti
    mov     rdi, r13
    call    r12
    call    kernel_thread_return

1:

    hlt
    jmp     1b

.global user_trampoline

user_trampoline:

    call    kernel_after_switch

    mov     ax, 0x1b                // user data | RPL3
    movzx   rax, ax
    push    rax
    push    r13
    mov     rax, 0x202
    push    rax
    mov     ax, 0x23                // user code | RPL3
    movzx   rax, ax
    push    rax
    push    r12
    mov     rdi, r14
    iretq
