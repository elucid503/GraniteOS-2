/* aarch64 kernel image layout: loaded at RAM base + 0x80000, identity-mapped (link address == run address) for M0. */

ENTRY(_start)

KERNEL_PHYS_BASE = 0x40080000;

SECTIONS {

    . = KERNEL_PHYS_BASE;
    __kernel_start = .;

    .text : ALIGN(4096) {

        KEEP(*(.text.boot))
        *(.text.vectors)
        *(.text .text.*)

    }

    /* The M3 user-mode programs: a position-independent blob the kernel copies into each process and maps at EL0.
       Page-aligned and bounded so boot can copy exactly [__user_text_start, __user_text_end) into a user Region. */

    .user_text : ALIGN(4096) {

        __user_text_start = .;
        KEEP(*(.user_text))
        . = ALIGN(4096);
        __user_text_end = .;

    }

    .rodata : ALIGN(4096) {

        *(.rodata .rodata.*)

    }

    .data : ALIGN(4096) {

        *(.data .data.*)

    }

    .bss : ALIGN(4096) {

        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;

    }

    /* The boot stack lives past the BSS, outside [__bss_start, __bss_end), so the zeroing loop never walks over it. */

    . = ALIGN(4096);
    __boot_stack_bottom = .;
    . += 0x10000;
    __boot_stack_top = .;

    __kernel_end = .;

    /* Total memory footprint for the ARM64 Image header's image_size field. */

    __image_size = __kernel_end - __kernel_start;

    /DISCARD/ : {

        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)

    }

}
