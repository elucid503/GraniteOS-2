// x86_64 CPU control: identity, barriers, interrupt mask, port I/O, halt.

const build_options = @import("build_options");

pub fn core_id() u32 {

    return 0;

}

pub fn wait_for_event() void {

    asm volatile ("hlt");

}

pub fn wait_for_interrupt() void {

    asm volatile ("sti; hlt; cli");

}

pub fn send_event() void {}

pub fn sync_instruction_cache() void {

    asm volatile ("mfence" ::: .{ .memory = true });

}

pub fn clean_invalidate_data_cache(base: usize, length: usize) void {

    _ = base;
    _ = length;
    // Single-core bring-up: a full fence is enough for DMA visibility on QEMU.
    asm volatile ("mfence" ::: .{ .memory = true });

}

pub const InterruptState = usize;

pub fn enable_interrupts() void {

    asm volatile ("sti");

}

pub fn disable_interrupts() InterruptState {

    const flags = asm volatile (
        \\ pushfq
        \\ popq %[out]
        \\ cli
        : [out] "=r" (-> u64),
    );

    return flags;

}

pub fn restore_interrupts(state: InterruptState) void {

    if (state & 0x200 != 0) {

        asm volatile ("sti");

    } else {

        asm volatile ("cli");

    }

}

pub fn halt() noreturn {

    if (build_options.@"test") {

        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (@as(u8, 0)),
              [port] "{dx}" (@as(u16, 0x501)),
        );

    }

    asm volatile ("cli");

    while (true) {

        asm volatile ("hlt");

    }

}

pub fn park() noreturn {

    asm volatile ("cli");

    while (true) {

        asm volatile ("hlt");

    }

}

pub fn port_in(width: u8, port: u16) u32 {

    return switch (width) {

        1 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8),
            : [port] "{dx}" (port),
        ),

        2 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> u16),
            : [port] "{dx}" (port),
        ),

        4 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> u32),
            : [port] "{dx}" (port),
        ),

        else => 0,

    };

}

pub fn port_out(width: u8, port: u16, value: u32) void {

    switch (width) {

        1 => asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (@as(u8, @truncate(value))),
              [port] "{dx}" (port),
        ),

        2 => asm volatile ("outw %[value], %[port]"
            :
            : [value] "{ax}" (@as(u16, @truncate(value))),
              [port] "{dx}" (port),
        ),

        4 => asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "{dx}" (port),
        ),

        else => {},

    }

}

pub fn read_msr(index: u32) u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [index] "{ecx}" (index),
    );

    return (@as(u64, high) << 32) | low;

}

pub fn write_msr(index: u32, value: u64) void {

    asm volatile ("wrmsr"
        :
        : [index] "{ecx}" (index),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
    );

}

pub fn read_cr3() u64 {

    return asm volatile ("movq %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );

}

pub fn write_cr3(value: u64) void {

    asm volatile ("movq %[value], %%cr3"
        :
        : [value] "r" (value),
        : .{ .memory = true });

}

pub const IdtPointer = extern struct {

    limit: u16,
    base: u64 align(1),

};

pub const GdtPointer = extern struct {

    limit: u16,
    base: u64 align(1),

};

pub extern fn load_idt(pointer: *const IdtPointer) void;
pub extern fn load_gdt(pointer: *const GdtPointer) void;
pub extern fn load_tr(selector: u16) void;

pub fn lidt(pointer: *const IdtPointer) void {

    load_idt(pointer);

}

pub fn lgdt(pointer: *const GdtPointer) void {

    load_gdt(pointer);

}

pub fn ltr(selector: u16) void {

    load_tr(selector);

}

pub fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };

}

pub fn rdtsc() u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return (@as(u64, high) << 32) | low;

}
