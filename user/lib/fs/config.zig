// Per-app config files under /cfgs: one `<name>.config` file each.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const fs = @import("fs.zig");
const layout = @import("layout.zig");
const proto = @import("../ipc/proto.zig");
const sys = @import("../syscall/sys.zig");

pub const dir = layout.cfgs;
pub const extension = ".config";

const max_name = 48;
const max_path = 128;

pub const Error = sys.Error || error{
    NameTooLong,
    PathTooLong,
};

/// Build `/cfgs/<name>.config` into `out`.
pub fn path(name: []const u8, out: []u8) Error![]const u8 {

    if (name.len == 0 or name.len > max_name) return error.NameTooLong;

    for (name) |byte| {

        const ok = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_';

        if (!ok) return error.NameTooLong;

    }

    const written = std.fmt.bufPrint(out, "{s}/{s}{s}", .{ dir, name, extension }) catch return error.PathTooLong;

    return written;

}

/// Read the full contents of `/cfgs/<name>.config` into `out`.
pub fn load(name: []const u8, out: []u8) Error![]const u8 {

    var path_buffer: [max_path]u8 = undefined;
    const file_path = try path(name, &path_buffer);

    var client = try fs.Client.connect(cap.memory);
    defer client.close();

    const file = try client.open_path(file_path, 0);
    defer client.close_file(file) catch {};

    const read = try client.read(file, 0, out);

    return out[0..read];

}

/// Replace `/cfgs/<name>.config` with `data` (creates the file when missing).
pub fn save(name: []const u8, data: []const u8) Error!void {

    var path_buffer: [max_path]u8 = undefined;
    const file_path = try path(name, &path_buffer);

    var client = try fs.Client.connect(cap.memory);
    defer client.close();

    client.mkdir(dir) catch {};

    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = try client.open_path(file_path, flags);
    defer client.close_file(file) catch {};

    var offset: usize = 0;

    while (offset < data.len) {

        const chunk = @min(data.len - offset, fs.payload_capacity);
        const written = try client.write(file, offset, data[offset .. offset + chunk]);

        if (written == 0) return error.Invalid;

        offset += written;

    }

}

/// Delete `/cfgs/<name>.config` when present.
pub fn remove(name: []const u8) void {

    var path_buffer: [max_path]u8 = undefined;
    const file_path = path(name, &path_buffer) catch return;

    var client = fs.Client.connect(cap.memory) catch return;
    defer client.close();

    client.delete(file_path) catch {};

}

/// Load using an already-connected filesystem client.
pub fn load_with(client: *fs.Client, name: []const u8, out: []u8) Error![]const u8 {

    var path_buffer: [max_path]u8 = undefined;
    const file_path = try path(name, &path_buffer);

    const file = try client.open_path(file_path, 0);
    defer client.close_file(file) catch {};

    const read = try client.read(file, 0, out);

    return out[0..read];

}

/// Save using an already-connected filesystem client.
pub fn save_with(client: *fs.Client, name: []const u8, data: []const u8) Error!void {

    var path_buffer: [max_path]u8 = undefined;
    const file_path = try path(name, &path_buffer);

    client.mkdir(dir) catch {};

    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = try client.open_path(file_path, flags);
    defer client.close_file(file) catch {};

    var offset: usize = 0;

    while (offset < data.len) {

        const chunk = @min(data.len - offset, fs.payload_capacity);
        const written = try client.write(file, offset, data[offset .. offset + chunk]);

        if (written == 0) return error.Invalid;

        offset += written;

    }

}
