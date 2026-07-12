// Region-backed size-class heap (07-userspace-ddd.md Section 3.6).

const std = @import("std");

const cap = @import("../cap/cap.zig");
const sys = @import("../syscall/sys.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const page_size = 4096;
const class_count = 8;
const largest_class = 2048;

const FreeNode = struct {

    next: ?*FreeNode,

};

pub const Heap = struct {

    authority: Handle,
    free_lists: [class_count]?*FreeNode = [_]?*FreeNode{null} ** class_count,

    pub fn init(authority: Handle) Heap {

        return .{ .authority = authority };

    }

    pub fn alloc(self: *Heap, length: usize) Error![]u8 {

        const requested = @max(length, 1);

        if (requested > largest_class) return self.alloc_large(requested);

        const class = class_for(requested);

        if (self.free_lists[class] == null) try self.grow_class(class);

        const node = self.free_lists[class].?;

        self.free_lists[class] = node.next;

        const bytes: [*]u8 = @ptrCast(node);

        return bytes[0..length];

    }

    pub fn free(self: *Heap, memory: []u8) void {

        if (memory.len > largest_class) {

            sys.unmap(cap.self_space, @intFromPtr(memory.ptr)) catch {};

            return;

        }

        const class = class_for(@max(memory.len, 1));
        const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));

        node.* = .{ .next = self.free_lists[class] };
        self.free_lists[class] = node;

    }

    pub fn allocator(self: *Heap) std.mem.Allocator {

        return .{

            .ptr = self,
            .vtable = &allocator_vtable,

        };

    }

    fn grow_class(self: *Heap, class: usize) Error!void {

        const size = class_size(class);
        const region = try sys.create(.region, page_size, self.authority);
        const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);

        sys.close(region) catch {};

        var offset: usize = 0;

        while (offset + size <= page_size) : (offset += size) {

            const node: *FreeNode = @ptrFromInt(base + offset);

            node.* = .{ .next = self.free_lists[class] };
            self.free_lists[class] = node;

        }

    }

    fn alloc_large(self: *Heap, length: usize) Error![]u8 {

        const bytes = align_up(length, page_size);
        const region = try sys.create(.region, bytes, self.authority);
        const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);

        sys.close(region) catch {};

        const span: [*]u8 = @ptrFromInt(base);

        return span[0..length];

    }

};

fn class_for(length: usize) usize {

    var size: usize = 16;
    var class: usize = 0;

    while (size < length and class + 1 < class_count) : (class += 1) size *= 2;

    return class;

}

fn class_size(class: usize) usize {

    return @as(usize, 16) << @intCast(class);

}

fn align_up(value: usize, alignment: usize) usize {

    return (value + alignment - 1) & ~(alignment - 1);

}

fn allocator_alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {

    _ = alignment;
    _ = return_address;

    const self: *Heap = @ptrCast(@alignCast(context));
    const memory = self.alloc(length) catch return null;

    return memory.ptr;

}

fn allocator_resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {

    _ = context;
    _ = alignment;
    _ = return_address;

    if (memory.len > largest_class) return align_up(memory.len, page_size) >= new_length;

    return class_size(class_for(@max(memory.len, 1))) >= new_length;

}

fn allocator_remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {

    _ = context;
    _ = memory;
    _ = alignment;
    _ = new_length;
    _ = return_address;

    return null;

}

fn allocator_free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {

    _ = alignment;
    _ = return_address;

    const self: *Heap = @ptrCast(@alignCast(context));

    self.free(memory);

}

const allocator_vtable = std.mem.Allocator.VTable{

    .alloc = allocator_alloc,
    .resize = allocator_resize,
    .remap = allocator_remap,
    .free = allocator_free,

};

test "size classes round upward" {

    try std.testing.expectEqual(@as(usize, 0), class_for(1));
    try std.testing.expectEqual(@as(usize, 0), class_for(16));
    try std.testing.expectEqual(@as(usize, 1), class_for(17));
    try std.testing.expectEqual(@as(usize, 7), class_for(2048));

}
