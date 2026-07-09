/* x86_64 Multiboot1 ELF: keep the header in the first LOAD (first 8 KiB of the file). */

ENTRY(_start)

SECTIONS {

    . = 0x100000;
    __kernel_start = .;

    .text : ALIGN(4) {

        KEEP(*(.multiboot))
        KEEP(*(.text.boot))
        *(.text .text.*)

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

    /* Boot stack sits past BSS so the early zeroing loop never walks over it. */

    . = ALIGN(4096);
    __boot_stack_bottom = .;
    . += 0x10000;
    __boot_stack_top = .;

    __kernel_end = .;

    /DISCARD/ : {

        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)

    }

}
