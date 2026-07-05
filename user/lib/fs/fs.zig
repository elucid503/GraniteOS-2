// Filesystem client (07-userspace-ddd.md Section 10.3): typed calls over the Filesystem interface with the
// per-session shared buffer of 05-server-protocol.md. Paths ride at the front of the buffer, file data and result
// records in the payload half; both are (offset, length) pairs into the one attached Region.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const buffer_size = 8192;
const path_offset = 0;
const path_capacity = 4096;
const payload_offset = 4096;

// Canonical paths are bounded by the server's own path limit (servers/filesystem/main.zig max_path).
const max_abs = 512;

/// The largest span one read/write/list call can move through the session buffer.
pub const payload_capacity = 4096;

/// Resolve `path` against absolute `base`, collapsing "." and ".." into a canonical absolute path written to `out`.
/// A leading "/" makes `path` absolute; otherwise it extends `base`. The filesystem server itself is path-stateless,
/// so this is where a client's working directory (07-userspace-ddd.md Section 8) is applied.
pub fn canonicalize(base: []const u8, path: []const u8, out: []u8) Error![]const u8 {

    if (path.len == 0) return error.Invalid;

    var length: usize = 0;

    if (path[0] != '/') {

        var seed = base;

        if (seed.len > 0 and seed[seed.len - 1] == '/') seed = seed[0 .. seed.len - 1];

        if (seed.len > 0) {

            if (seed.len > out.len) return error.Invalid;

            @memcpy(out[0..seed.len], seed);
            length = seed.len;

        }

    }

    var components = std.mem.tokenizeScalar(u8, path, '/');

    while (components.next()) |component| {

        if (component.len == 1 and component[0] == '.') continue;

        if (component.len == 2 and component[0] == '.' and component[1] == '.') {

            length = pop_component(out[0..length]);
            continue;

        }

        if (length + 1 + component.len > out.len) return error.Invalid;

        out[length] = '/';
        length += 1;

        @memcpy(out[length .. length + component.len], component);
        length += component.len;

    }

    if (length == 0) {

        out[0] = '/';
        return out[0..1];

    }

    return out[0..length];

}

fn pop_component(path: []const u8) usize {

    var index = path.len;

    while (index > 0) {

        index -= 1;

        if (path[index] == '/') return index;

    }

    return 0;

}

const builtin = @import("builtin");

const io = @import("../io/io.zig");
const start = if (builtin.target.cpu.arch == .aarch64) @import("../runtime/start.zig") else @import("../runtime/host_start.zig");

/// The shared shape of the one-path fs programs (create, mkdir, delete): connect, act, report.
pub fn simple_path_program(name: []const u8, args: []const []const u8, action: *const fn (*Client, []const u8) Error!void) u8 {

    const out = start.stdout() catch return 1;

    if (args.len < 2) {

        io.write(out, "usage: ") catch {};
        io.write(out, name) catch {};
        io.writeln(out, " <path>") catch {};

        return 1;

    }

    var client = Client.connect(cap.memory) catch {

        io.write(out, name) catch {};
        io.writeln(out, ": filesystem unavailable") catch {};

        return 1;

    };

    action(&client, args[1]) catch |failure| {

        io.print(out, "{s}: {s}: {s}\n", .{ name, args[1], describe(failure) }) catch {};

        return 1;

    };

    return 0;

}

/// Human-readable cause for a failed filesystem call, shared by the fs programs.
pub fn describe(failure: Error) []const u8 {

    return switch (failure) {

        error.NotFound => "not found",
        error.NoMemory => "out of space",
        error.NotAllowed => "not allowed",
        error.Gone => "filesystem unavailable",

        else => "invalid path or argument",

    };

}

pub const Client = struct {

    endpoint: Handle,
    buffer: Handle,

    base: usize,

    // The working directory relative paths resolve against, taken from the runtime's init message.
    cwd: []const u8,

    /// Resolve the "filesystem" service through the name service and open a session with it.
    pub fn connect(authority: Handle) Error!Client {

        return open(try stream.lookup_endpoint("filesystem"), authority);

    }

    /// Share the session buffer with an already-resolved filesystem endpoint.
    pub fn open(endpoint: Handle, authority: Handle) Error!Client {

        const buffer = try sys.create(.region, buffer_size, authority);
        const base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);

        _ = try ipc.request(endpoint, proto.filesystem.attach, &.{buffer_size}, &.{

            .{ .handle = buffer, .move = false },

        });

        return .{

            .endpoint = endpoint,
            .buffer = buffer,

            .base = base,

            .cwd = start.cwd(),

        };

    }

    pub fn open_path(self: *Client, path: []const u8, flags: u64) Error!u64 {

        const span = try self.put_path(path);
        const reply = try ipc.request(self.endpoint, proto.filesystem.open, &.{ span.offset, span.length, flags }, &.{});

        return reply.data[0];

    }

    pub fn close_file(self: *Client, file: u64) Error!void {

        _ = try ipc.request(self.endpoint, proto.filesystem.close, &.{file}, &.{});

    }

    pub fn read(self: *Client, file: u64, offset: u64, out: []u8) Error!usize {

        const amount = @min(out.len, payload_capacity);
        const reply = try ipc.request(self.endpoint, proto.filesystem.read, &.{ file, offset, payload_offset, amount }, &.{});
        const length: usize = @intCast(reply.data[0]);

        @memcpy(out[0..length], self.payload()[0..length]);

        return length;

    }

    pub fn write(self: *Client, file: u64, offset: u64, bytes: []const u8) Error!usize {

        const amount = @min(bytes.len, payload_capacity);

        @memcpy(self.payload()[0..amount], bytes[0..amount]);

        const reply = try ipc.request(self.endpoint, proto.filesystem.write, &.{ file, offset, payload_offset, amount }, &.{});

        return @intCast(reply.data[0]);

    }

    pub fn create(self: *Client, path: []const u8, kind: u64) Error!void {

        const span = try self.put_path(path);

        _ = try ipc.request(self.endpoint, proto.filesystem.create, &.{ span.offset, span.length, kind }, &.{});

    }

    pub fn delete(self: *Client, path: []const u8) Error!void {

        const span = try self.put_path(path);

        _ = try ipc.request(self.endpoint, proto.filesystem.delete, &.{ span.offset, span.length }, &.{});

    }

    pub fn rename(self: *Client, old: []const u8, new: []const u8) Error!void {

        var old_scratch: [max_abs]u8 = undefined;
        var new_scratch: [max_abs]u8 = undefined;

        const from = try canonicalize(self.cwd, old, &old_scratch);
        const to = try canonicalize(self.cwd, new, &new_scratch);

        if (from.len + to.len > path_capacity) return error.Invalid;

        const bytes: [*]u8 = @ptrFromInt(self.base + path_offset);

        @memcpy(bytes[0..from.len], from);
        @memcpy(bytes[from.len .. from.len + to.len], to);

        _ = try ipc.request(self.endpoint, proto.filesystem.rename, &.{ path_offset, from.len, path_offset + from.len, to.len }, &.{});

    }

    /// Fill the payload half of the session buffer with `proto.filesystem.Entry` records; returns them.
    pub fn list(self: *Client, path: []const u8) Error![]const proto.filesystem.Entry {

        const span = try self.put_path(path);
        const reply = try ipc.request(self.endpoint, proto.filesystem.list, &.{ span.offset, span.length, payload_offset, payload_capacity }, &.{});
        const bytes: usize = @intCast(reply.data[0]);

        const records: [*]const proto.filesystem.Entry = @ptrFromInt(self.base + payload_offset);

        return records[0 .. bytes / @sizeOf(proto.filesystem.Entry)];

    }

    pub fn stat(self: *Client, path: []const u8) Error!proto.filesystem.Stat {

        const span = try self.put_path(path);

        _ = try ipc.request(self.endpoint, proto.filesystem.stat, &.{ span.offset, span.length, payload_offset }, &.{});

        const record: *const proto.filesystem.Stat = @ptrFromInt(self.base + payload_offset);

        return record.*;

    }

    pub fn info(self: *Client) Error!proto.filesystem.Info {

        _ = try ipc.request(self.endpoint, proto.filesystem.info, &.{payload_offset}, &.{});

        const record: *const proto.filesystem.Info = @ptrFromInt(self.base + payload_offset);

        return record.*;

    }

    pub fn mkdir(self: *Client, path: []const u8) Error!void {

        const span = try self.put_path(path);

        _ = try ipc.request(self.endpoint, proto.filesystem.mkdir, &.{ span.offset, span.length }, &.{});

    }

    pub fn set_permissions(self: *Client, path: []const u8, mask: u64) Error!void {

        const span = try self.put_path(path);

        _ = try ipc.request(self.endpoint, proto.filesystem.set_permissions, &.{ span.offset, span.length, mask }, &.{});

    }

    const Span = struct {

        offset: u64,
        length: u64,

    };

    fn put_path(self: *Client, path: []const u8) Error!Span {

        var scratch: [max_abs]u8 = undefined;
        const absolute = try canonicalize(self.cwd, path, &scratch);

        const bytes: [*]u8 = @ptrFromInt(self.base + path_offset);

        @memcpy(bytes[0..absolute.len], absolute);

        return .{

            .offset = path_offset,
            .length = absolute.len,

        };

    }

    fn payload(self: *Client) []u8 {

        const bytes: [*]u8 = @ptrFromInt(self.base + payload_offset);

        return bytes[0..payload_capacity];

    }

};
