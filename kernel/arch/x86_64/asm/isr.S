.intel_syntax noprefix

.section .text

.macro ISR_NOERR num
.global isr_\num
isr_\num:
    push    0
    push    \num
    jmp     isr_common
.endm

.macro ISR_ERR num
.global isr_\num
isr_\num:
    push    \num
    jmp     isr_common
.endm

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR 8
ISR_NOERR 9
ISR_ERR 10
ISR_ERR 11
ISR_ERR 12
ISR_ERR 13
ISR_ERR 14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR 17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_NOERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_ERR 30
ISR_NOERR 31

.macro IRQ_STUB num
.global isr_\num
isr_\num:
    push    0
    push    \num
    jmp     irq_common
.endm

IRQ_STUB 32
IRQ_STUB 33
IRQ_STUB 34
IRQ_STUB 35
IRQ_STUB 36
IRQ_STUB 37
IRQ_STUB 38
IRQ_STUB 39
IRQ_STUB 40
IRQ_STUB 41
IRQ_STUB 42
IRQ_STUB 43
IRQ_STUB 44
IRQ_STUB 45
IRQ_STUB 46
IRQ_STUB 47
IRQ_STUB 48
IRQ_STUB 49
IRQ_STUB 50

isr_common:

    push    r15
    push    r14
    push    r13
    push    r12
    push    r11
    push    r10
    push    r9
    push    r8
    push    rdi
    push    rsi
    push    rbp
    push    rdx
    push    rcx
    push    rbx
    push    rax

    mov     rdi, rsp
    call    kernel_trap

1:
    hlt
    jmp     1b

irq_common:

    push    r15
    push    r14
    push    r13
    push    r12
    push    r11
    push    r10
    push    r9
    push    r8
    push    rdi
    push    rsi
    push    rbp
    push    rdx
    push    rcx
    push    rbx
    push    rax

    mov     rdi, rsp
    call    kernel_irq

    pop     rax
    pop     rbx
    pop     rcx
    pop     rdx
    pop     rbp
    pop     rsi
    pop     rdi
    pop     r8
    pop     r9
    pop     r10
    pop     r11
    pop     r12
    pop     r13
    pop     r14
    pop     r15
    add     rsp, 16
    iretq

.global syscall_entry
syscall_entry:

    mov     [rip + user_rsp_scratch], rsp
    mov     rsp, [rip + syscall_stack_top]

    push    r11
    push    rcx
    push    r15
    push    r14
    push    r13
    push    r12
    push    r10
    push    r9
    push    r8
    push    rdi
    push    rsi
    push    rbp
    push    rdx
    push    rbx
    push    rax

    mov     rdi, rsp
    call    kernel_syscall

    pop     rax
    pop     rbx
    pop     rdx
    pop     rbp
    pop     rsi
    pop     rdi
    pop     r8
    pop     r9
    pop     r10
    pop     r12
    pop     r13
    pop     r14
    pop     r15
    pop     rcx
    pop     r11

    mov     rsp, [rip + user_rsp_scratch]
    sysretq

.section .data
.align 8

.global syscall_stack_top
syscall_stack_top:

    .quad syscall_stack + 0x8000

.section .bss
.align 16

user_rsp_scratch:

    .quad 0

.align 4096
syscall_stack:

    .space 0x8000
