.intel_syntax noprefix

.section .text
.global load_idt
load_idt:

    lidt    [rdi]
    ret

.global load_gdt
load_gdt:

    lgdt    [rdi]
    ret

.global load_tr
load_tr:

    ltr     di
    ret
