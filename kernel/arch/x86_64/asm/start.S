// x86_64 Multiboot2 entry: 32-bit protected mode -> long mode, then Zig.
// Boot markers live here so the Windows-hosted assembler does not depend on GNU ld script symbols.

.intel_syntax noprefix

.section .text.boot, "ax"
.code32
.align 4

.global multiboot_header
multiboot_header:

    .long 0x1BADB002
    .long 0x00000000
    .long 0xE4524FFE

.global _start
.global __kernel_start
__kernel_start:
_start:

    cli
    mov     esp, offset __boot_stack_top
    mov     dword ptr [mb2_info_phys], ebx

    // Zero the full linker BSS (Zig globals + boot tables) before building page tables.

    mov     edi, offset __bss_start
    mov     ecx, offset __bss_end
    sub     ecx, edi
    xor     eax, eax
    shr     ecx, 2
    rep     stosd

    // Identity-map the first 4 GiB with 2 MiB pages.

    mov     eax, offset boot_pdpt
    or      eax, 0x03
    mov     dword ptr [boot_pml4], eax

    mov     eax, offset boot_pd0
    or      eax, 0x03
    mov     dword ptr [boot_pdpt], eax
    mov     eax, offset boot_pd1
    or      eax, 0x03
    mov     dword ptr [boot_pdpt + 8], eax
    mov     eax, offset boot_pd2
    or      eax, 0x03
    mov     dword ptr [boot_pdpt + 16], eax
    mov     eax, offset boot_pd3
    or      eax, 0x03
    mov     dword ptr [boot_pdpt + 24], eax

    mov     edi, offset boot_pd0
    xor     eax, eax
    or      eax, 0x83
    mov     ecx, 512 * 4

fill_pd:

    mov     dword ptr [edi], eax
    add     edi, 8
    add     eax, 0x200000
    loop    fill_pd

    mov     eax, offset boot_pml4
    mov     cr3, eax

    mov     eax, cr4
    or      eax, (1 << 5)
    mov     cr4, eax

    mov     ecx, 0xC0000080
    rdmsr
    or      eax, (1 << 8)
    wrmsr

    mov     eax, cr0
    or      eax, (1 << 31) | 1
    mov     cr0, eax

    lgdt    [gdt_pointer]
    ljmp    0x08, offset long_mode_entry

.code64
long_mode_entry:

    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     fs, ax
    mov     gs, ax

    // Enable SSE/SSE2 so Zig-generated code does not #UD on movaps/etc.
    mov     rax, cr0
    and     rax, ~0x4                 // clear EM
    or      rax, 0x2                  // set MP
    mov     cr0, rax
    mov     rax, cr4
    or      rax, 0x600                // OSFXSR | OSXMMEXCPT
    mov     cr4, rax
    fninit

    mov     rsp, offset __boot_stack_top

    mov     edi, dword ptr [mb2_info_phys]
    call    kernel_boot

hang:

    hlt
    jmp     hang

.section .data
.align 8

mb2_info_phys:

    .long 0

.align 16
.global gdt
gdt:

    .quad 0
    .quad 0x00af9a000000ffff
    .quad 0x00cf92000000ffff
    .quad 0x00cff2000000ffff
    .quad 0x00affa000000ffff
    .quad 0
    .quad 0

gdt_pointer:

    .word gdt_end - gdt - 1
    .quad gdt

gdt_end:

.section .bss
.align 4096

.global boot_pml4
boot_pml4:

    .space 4096

boot_pdpt:

    .space 4096

boot_pd0:

    .space 4096

boot_pd1:

    .space 4096

boot_pd2:

    .space 4096

boot_pd3:

    .space 4096

// Boot stack and __kernel_end / __bss_* come from the linker script so Zig .bss is reserved too.
