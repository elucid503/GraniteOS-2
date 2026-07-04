/* The Flint image: static, non-PIE, linked at the fixed user window base so the kernel raw-maps it with no
   ELF parsing (06-kernel-ddd.md Section 13). Must match config.user_space_base. `.text.start` comes first so the
   image base is the entry point. One flat RWX span for M4; a text/data split is a later hardening step. */

ENTRY(_start)

USER_BASE = 0x8000000000;

SECTIONS {

    . = USER_BASE;
    __image_start = .;

    .text : {

        KEEP(*(.text.start))
        *(.text .text.*)

    }

    .rodata : ALIGN(16) {

        *(.rodata .rodata.*)

    }

    .data : ALIGN(16) {

        *(.data .data.*)

    }

    .bss : ALIGN(16) {

        *(.bss .bss.*)
        *(COMMON)

    }

    /* The flatten tool pads the image to the memory extent, so the raw-mapped BSS arrives as explicit zeros. */

    . = ALIGN(4096);
    __image_end = .;

    /DISCARD/ : {

        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)

    }

}
