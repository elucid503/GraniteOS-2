// M6 name service: a tiny single-threaded map from inline service names to Endpoint handles.

const std = @import("std");
const builtin = @import("builtin");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    if (builtin.target.cpu.arch == .aarch64) _ = lib.start;

}

const max_names = 16;

const Entry = struct {

    name: [proto.name.max_length]u8 = [_]u8{0} ** proto.name.max_length,
    len: usize = 0,
    endpoint: Handle = 0,
    active: bool = false,

};

const Table = struct {

    entries: [max_names]Entry = [_]Entry{.{}} ** max_names,

    fn register(self: *Table, name: []const u8, endpoint: Handle) !void {

        if (name.len > proto.name.max_length) return error.Invalid;

        const slot = self.find_slot(name) orelse self.free_slot() orelse return error.NoMemory;

        slot.name = [_]u8{0} ** proto.name.max_length;
        @memcpy(slot.name[0..name.len], name);
        slot.len = name.len;
        slot.endpoint = endpoint;
        slot.active = true;

    }

    fn lookup(self: *Table, name: []const u8) ?Handle {

        const slot = self.find_slot(name) orelse return null;

        return slot.endpoint;

    }

    fn unregister(self: *Table, name: []const u8) bool {

        const slot = self.find_slot(name) orelse return false;

        slot.active = false;

        return true;

    }

    fn find_slot(self: *Table, name: []const u8) ?*Entry {

        for (&self.entries) |*entry| {

            if (!entry.active) continue;
            if (std.mem.eql(u8, entry.name[0..entry.len], name)) return entry;

        }

        return null;

    }

    fn free_slot(self: *Table) ?*Entry {

        for (&self.entries) |*entry| {

            if (!entry.active) return entry;

        }

        return null;

    }

};

var table: Table = .{};

// Lookup returns a uniquely badged endpoint copy; minted badges start above Flint/Marble grant badges.

const first_minted_badge: u64 = 64;

var next_badge: u64 = first_minted_badge;

pub fn main(_: []const []const u8) u8 {

    ipc.serve(cap.server.endpoint, dispatch);

}

fn dispatch(_: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.name.register => register(in),
        proto.name.lookup => lookup(in, out),
        proto.name.list => list(out),
        proto.name.unregister => unregister(in),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.name.interface_id;
    out.data[2] = proto.name.version;

    return 0;

}

fn register(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    var name_buffer: [proto.name.max_length]u8 = undefined;
    const name = decode_name(in, &name_buffer) orelse return -7;

    table.register(name, in.handles[0].handle) catch return -7;

    return 0;

}

fn lookup(in: *const Message, out: *Message) i64 {

    var name_buffer: [proto.name.max_length]u8 = undefined;
    const name = decode_name(in, &name_buffer) orelse return -7;
    const endpoint = table.lookup(name) orelse return -6;

    next_badge += 1;
    const badged = sys.copy(endpoint, next_badge) catch return -3;

    // move: the minted copy is a throwaway that belongs to the caller, so it must not linger in this table.

    out.handles[0] = .{ .handle = badged, .move = true };
    out.handle_count = 1;

    return 0;

}

fn list(out: *Message) i64 {

    var count: u64 = 0;

    for (&table.entries) |*entry| {

        if (entry.active) count += 1;

    }

    out.data[1] = count;

    return 0;

}

fn unregister(in: *const Message) i64 {

    var name_buffer: [proto.name.max_length]u8 = undefined;
    const name = decode_name(in, &name_buffer) orelse return -7;

    return if (table.unregister(name)) 0 else -6;

}

fn decode_name(in: *const Message, out: *[proto.name.max_length]u8) ?[]const u8 {

    const length: usize = @intCast(in.data[1]);

    if (length > proto.name.max_length) return null;

    out.* = [_]u8{0} ** proto.name.max_length;

    for (0..4) |index| {

        std.mem.writeInt(u64, out.*[index * 8 ..][0..8], in.data[index + 2], .little);

    }

    return out.*[0..length];

}

test "table register lookup replace and unregister" {

    var local: Table = .{};

    try local.register("console", 10);
    try std.testing.expectEqual(@as(?Handle, 10), local.lookup("console"));

    try local.register("console", 11);
    try std.testing.expectEqual(@as(?Handle, 11), local.lookup("console"));

    try std.testing.expect(local.unregister("console"));
    try std.testing.expectEqual(@as(?Handle, null), local.lookup("console"));

}
