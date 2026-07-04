// User-space ELF loader and spawn helper for M6 programs. It handles static non-PIE ELF64 images only.

const std = @import("std");

const cap = @import("cap.zig");
const ipc = @import("ipc.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const page_size = 4096;
const stack_pages = 16;
const stack_base = 0x80_1000_0000;

const e_entry = 0x18;
const e_phoff = 0x20;
const e_phentsize = 0x36;
const e_phnum = 0x38;

const p_type = 0x00;
const p_flags = 0x04;
const p_offset = 0x08;
const p_vaddr = 0x10;
const p_filesz = 0x20;
const p_memsz = 0x28;

const pt_load = 1;

pub const Loaded = struct {

    space: Handle,
    entry: usize,
    stack: usize,

};

pub const SpawnArgs = struct {

    image: []const u8,
    authority: Handle,
    args: []const []const u8,
    grants: []const Handle,
    flags: u64 = 0,
    data3: u64 = 0,
    data4: u64 = 0,

};

pub fn load(image: []const u8, authority: Handle) Error!Loaded {

    if (image.len < 64) return error.Invalid;

    const space = try sys.create(.address_space, 0, 0);
    const program_header_offset: usize = @intCast(read_u64(image, e_phoff));
    const program_header_size: usize = read_u16(image, e_phentsize);
    const program_header_count: usize = read_u16(image, e_phnum);
    const image_base, const image_length = try image_span(image, program_header_offset, program_header_size, program_header_count);

    const image_region = try sys.create(.region, image_length, authority);
    const staging = try sys.map(cap.self_space, image_region, 0, sys.read | sys.write);
    const destination: [*]u8 = @ptrFromInt(staging);

    @memset(destination[0..image_length], 0);

    for (0..program_header_count) |index| {

        const header = program_header_offset + index * program_header_size;

        if (header + 56 > image.len) return error.Invalid;
        if (read_u32(image, header + p_type) != pt_load) continue;

        const memory_size: usize = @intCast(read_u64(image, header + p_memsz));
        const file_size: usize = @intCast(read_u64(image, header + p_filesz));
        const file_offset: usize = @intCast(read_u64(image, header + p_offset));
        const virtual_address: usize = @intCast(read_u64(image, header + p_vaddr));

        if (memory_size == 0) continue;
        if (file_size > memory_size) return error.Invalid;
        if (file_offset + file_size > image.len) return error.Invalid;

        const destination_offset = virtual_address - image_base;

        @memcpy(destination[destination_offset .. destination_offset + file_size], image[file_offset .. file_offset + file_size]);

    }

    try sys.unmap(cap.self_space, staging);

    const mapped = try sys.map(space, image_region, image_base, sys.read | sys.write | sys.execute);

    if (mapped != image_base) return error.Invalid;

    const stack_region = try sys.create(.region, stack_pages * page_size, authority);
    const mapped_stack = try sys.map(space, stack_region, stack_base, sys.read | sys.write);

    return .{

        .space = space,
        .entry = @intCast(read_u64(image, e_entry)),
        .stack = mapped_stack + stack_pages * page_size,

    };

}

fn image_span(image: []const u8, program_header_offset: usize, program_header_size: usize, program_header_count: usize) Error!struct { usize, usize } {

    var base: usize = std.math.maxInt(usize);
    var end: usize = 0;

    for (0..program_header_count) |index| {

        const header = program_header_offset + index * program_header_size;

        if (header + 56 > image.len) return error.Invalid;
        if (read_u32(image, header + p_type) != pt_load) continue;

        const memory_size: usize = @intCast(read_u64(image, header + p_memsz));
        const file_size: usize = @intCast(read_u64(image, header + p_filesz));
        const file_offset: usize = @intCast(read_u64(image, header + p_offset));
        const virtual_address: usize = @intCast(read_u64(image, header + p_vaddr));

        if (memory_size == 0) continue;
        if (file_size > memory_size) return error.Invalid;
        if (file_offset + file_size > image.len) return error.Invalid;

        base = @min(base, align_down(virtual_address, page_size));
        end = @max(end, align_up(virtual_address + memory_size, page_size));

    }

    if (end <= base) return error.Invalid;

    return .{ base, end - base };

}

pub fn spawn_program(args: SpawnArgs) Error!Handle {

    const loaded = try load(args.image, args.authority);
    const init = try build_args(args.authority, args.args);
    const child = try sys.spawn(loaded.space, loaded.entry, loaded.stack, args.grants);

    var message = ipc.Message.zeroed;

    message.data[0] = args.args.len;
    message.data[1] = init.length;
    message.data[2] = args.flags;
    message.data[3] = args.data3;
    message.data[4] = args.data4;
    message.handles[0] = .{ .handle = init.region, .move = true };
    message.handle_count = 1;

    try sys.send(args.grants[cap.startup_endpoint], &message);

    return child;

}

const PackedArgs = struct {

    region: Handle,
    length: usize,

};

fn build_args(authority: Handle, args: []const []const u8) Error!PackedArgs {

    var length: usize = 0;

    for (args) |arg| {

        length += arg.len + 1;

    }

    const region = try sys.create(.region, @max(length, 1), authority);
    const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
    const bytes: [*]u8 = @ptrFromInt(base);

    var cursor: usize = 0;

    for (args) |arg| {

        @memcpy(bytes[cursor .. cursor + arg.len], arg);
        cursor += arg.len;
        bytes[cursor] = 0;
        cursor += 1;

    }

    try sys.unmap(cap.self_space, base);

    return .{

        .region = region,
        .length = length,

    };

}

fn align_down(value: usize, alignment: usize) usize {

    return value & ~(alignment - 1);

}

fn align_up(value: usize, alignment: usize) usize {

    return (value + alignment - 1) & ~(alignment - 1);

}

fn read_u16(bytes: []const u8, offset: usize) u16 {

    return std.mem.readInt(u16, bytes[offset..][0..2], .little);

}

fn read_u32(bytes: []const u8, offset: usize) u32 {

    return std.mem.readInt(u32, bytes[offset..][0..4], .little);

}

fn read_u64(bytes: []const u8, offset: usize) u64 {

    return std.mem.readInt(u64, bytes[offset..][0..8], .little);

}
