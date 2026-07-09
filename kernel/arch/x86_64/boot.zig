// Multiboot1 discovery + IDT/GDT/TSS/syscall MSR bring-up, then hand off to main.

const std = @import("std");

const console = @import("console.zig");
const mmu = @import("mmu.zig");
const cpu = @import("cpu.zig");
const board = @import("../board/pc.zig");
const platform = @import("../../boot/platform.zig");
const machine_module = @import("../../boot/machine.zig");
const config = @import("../../config.zig");
const panic_path = @import("../../debug/panic.zig");

extern const gdt: [7]u64;
extern fn isr_0() void;
extern fn isr_1() void;
extern fn isr_2() void;
extern fn isr_3() void;
extern fn isr_4() void;
extern fn isr_5() void;
extern fn isr_6() void;
extern fn isr_7() void;
extern fn isr_8() void;
extern fn isr_9() void;
extern fn isr_10() void;
extern fn isr_11() void;
extern fn isr_12() void;
extern fn isr_13() void;
extern fn isr_14() void;
extern fn isr_15() void;
extern fn isr_16() void;
extern fn isr_17() void;
extern fn isr_18() void;
extern fn isr_19() void;
extern fn isr_20() void;
extern fn isr_21() void;
extern fn isr_22() void;
extern fn isr_23() void;
extern fn isr_24() void;
extern fn isr_25() void;
extern fn isr_26() void;
extern fn isr_27() void;
extern fn isr_28() void;
extern fn isr_29() void;
extern fn isr_30() void;
extern fn isr_31() void;
extern fn isr_32() void;
extern fn isr_33() void;
extern fn isr_34() void;
extern fn isr_35() void;
extern fn isr_36() void;
extern fn isr_37() void;
extern fn isr_38() void;
extern fn isr_39() void;
extern fn isr_40() void;
extern fn isr_41() void;
extern fn isr_42() void;
extern fn isr_43() void;
extern fn isr_44() void;
extern fn isr_45() void;
extern fn isr_46() void;
extern fn isr_47() void;
extern fn isr_48() void;
extern fn isr_49() void;
extern fn isr_50() void;
extern fn syscall_entry() void;

const IdtEntry = packed struct(u128) {

    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,

};

const Tss = extern struct {

    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),

};

const MultibootInfo = extern struct {

    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,

};

const MultibootModule = extern struct {

    mod_start: u32,
    mod_end: u32,
    string: u32,
    reserved: u32,

};

const MultibootMmap = extern struct {

    size: u32,
    base: u64,
    length: u64,
    kind: u32,

};

var idt: [256]IdtEntry align(16) = undefined;
var tss: Tss align(16) = .{};
var interrupt_stack: [0x4000]u8 align(16) = undefined;
var platform_info: platform.PlatformInfo align(4096) = .{};
var memory_banks: [16]machine_module.MemoryRange = undefined;
var cpu_ids: [config.max_cores]u64 = undefined;

export fn kernel_boot(mb_info: u64) callconv(.c) noreturn {

    console.init();
    mmu.enable_boot_mapping();
    install_idt();
    install_tss();
    install_syscall();

    const machine = parse_multiboot1(mb_info) catch {

        panic_path.panic("multiboot: could not parse boot info", null);

    };

    @import("root").main(machine);

}

fn install_idt() void {

    const handlers = [_]*const fn () callconv(.c) void{

        isr_0,  isr_1,  isr_2,  isr_3,  isr_4,  isr_5,  isr_6,  isr_7,
        isr_8,  isr_9,  isr_10, isr_11, isr_12, isr_13, isr_14, isr_15,
        isr_16, isr_17, isr_18, isr_19, isr_20, isr_21, isr_22, isr_23,
        isr_24, isr_25, isr_26, isr_27, isr_28, isr_29, isr_30, isr_31,
        isr_32, isr_33, isr_34, isr_35, isr_36, isr_37, isr_38, isr_39,
        isr_40, isr_41, isr_42, isr_43, isr_44, isr_45, isr_46, isr_47,
        isr_48, isr_49, isr_50,

    };

    for (&idt) |*entry| entry.* = .{

        .offset_low = 0,
        .selector = 0x08,
        .ist = 0,
        .type_attr = 0,
        .offset_mid = 0,
        .offset_high = 0,
        .reserved = 0,

    };

    for (handlers, 0..) |handler, index| {

        set_idt_entry(index, @intFromPtr(handler), 0x8e);

    }

    const pointer = cpu.IdtPointer{

        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),

    };

    cpu.lidt(&pointer);

}

fn set_idt_entry(index: usize, handler: usize, type_attr: u8) void {

    idt[index] = .{

        .offset_low = @truncate(handler),
        .selector = 0x08,
        .ist = 0,
        .type_attr = type_attr,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved = 0,

    };

}

fn install_tss() void {

    tss.rsp0 = @intFromPtr(&interrupt_stack) + interrupt_stack.len;

    const base = @intFromPtr(&tss);
    const limit = @sizeOf(Tss) - 1;

    const low =
        (@as(u64, @truncate(limit)) & 0xffff) |
        ((base & 0xffff) << 16) |
        (((base >> 16) & 0xff) << 32) |
        (@as(u64, 0x89) << 40) |
        (((@as(u64, @truncate(limit)) >> 16) & 0xf) << 48) |
        (((base >> 24) & 0xff) << 56);

    const high = base >> 32;

    const gdt_mut: *[7]u64 = @constCast(&gdt);
    gdt_mut[5] = low;
    gdt_mut[6] = high;

    const pointer = cpu.GdtPointer{

        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),

    };

    cpu.lgdt(&pointer);
    cpu.ltr(0x28);

}

fn install_syscall() void {

    const star = (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32);
    cpu.write_msr(0xC0000081, star);
    cpu.write_msr(0xC0000082, @intFromPtr(&syscall_entry));
    cpu.write_msr(0xC0000084, 0x200);

    const efer = cpu.read_msr(0xC0000080);
    cpu.write_msr(0xC0000080, efer | 1);

}

fn parse_multiboot1(info_addr: u64) !machine_module.Machine {

    if (info_addr == 0) return error.Invalid;

    const info: *const MultibootInfo = @ptrFromInt(info_addr);
    var memory_count: usize = 0;
    var initrd: ?machine_module.MemoryRange = null;

    if (info.flags & (1 << 6) != 0) {

        var offset: usize = 0;

        while (offset < info.mmap_length and memory_count < memory_banks.len) {

            const entry: *const MultibootMmap = @ptrFromInt(info.mmap_addr + offset);

            if (entry.kind == 1 and entry.length != 0) {

                memory_banks[memory_count] = .{

                    .base = @intCast(entry.base),
                    .length = @intCast(entry.length),

                };
                memory_count += 1;

            }

            offset += entry.size + 4;

        }

    } else if (info.flags & (1 << 0) != 0) {

        // mem_upper is KiB above 1 MiB.
        memory_banks[0] = .{ .base = 0x100000, .length = @as(usize, info.mem_upper) * 1024 };
        memory_count = 1;

    }

    if (memory_count == 0) {

        memory_banks[0] = .{ .base = 0x100000, .length = 512 * 1024 * 1024 - 0x100000 };
        memory_count = 1;

    }

    if (info.flags & (1 << 3) != 0 and info.mods_count > 0) {

        const module: *const MultibootModule = @ptrFromInt(info.mods_addr);

        if (module.mod_end > module.mod_start) {

            initrd = .{ .base = module.mod_start, .length = module.mod_end - module.mod_start };

        }

    }

    platform_info = .{

        .magic = platform.magic,
        .version = platform.version,
        .uart_kind = @intFromEnum(platform.UartKind.uart16550),
        .uart_base = board.com1_port,
        .uart_irq = board.com1_irq,
        .core_count = 1,

    };

    cpu_ids[0] = 0;

    return .{

        .memory = memory_banks[0..memory_count],
        .core_count = 1,
        .intctrl = .{

            .distributor = board.lapic_base,
            .redistributor = board.ioapic_base,
            .redistributor_stride = 0,

        },
        .initrd = initrd,
        .cpus = cpu_ids[0..1],
        .power = .none,
        .discovery = @intFromPtr(&platform_info),
        .discovery_length = @sizeOf(platform.PlatformInfo),

    };

}
