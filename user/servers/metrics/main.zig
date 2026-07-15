// Boot-time timezone from public IP via HTTP geo lookup; saves to prefs and exposes via IPC.

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

// ip-api.com's free tier serves plain HTTP (HTTPS is a paid feature there), matching this stack's client.
const geo_host = "ip-api.com";
const geo_path = "/json/?fields=status,offset,countryCode";

const State = struct {

    ready: bool = false,
    offset_minutes: i32 = 0,
    country: [2]u8 = .{ '?', '?' },

};

var state: State = .{};

pub fn main(_: []const []const u8) u8 {

    detect();
    ipc.serve(cap.server.endpoint, dispatch);

}

fn detect() void {

    lookup() catch return;

    lib.prefs.refresh();
    lib.prefs.tz_offset_minutes = state.offset_minutes;
    lib.prefs.save();

    // Broadcast live to open GUI clients; headless boot still has prefs persisted for later readers.

    var connection = lib.window.Connection.connect(cap.memory) catch return;

    lib.prefs.broadcast_change(&connection);

}

fn lookup() !void {

    var socket = try lib.net.Socket.connect_host(cap.memory, geo_host, 80);
    defer socket.close();

    var request_buffer: [160]u8 = undefined;
    const http_request = try std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ geo_path, geo_host });

    try socket.send_all(http_request);

    var response: [2048]u8 = undefined;
    var length: usize = 0;

    while (length < response.len) {

        const read = socket.recv(response[length..]) catch break;

        if (read == 0) break;

        length += read;

    }

    try parse_response(response[0..length]);

}

fn parse_response(bytes: []const u8) !void {

    const body_start = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.Invalid;
    const body = bytes[body_start + 4 ..];

    var status_buffer: [16]u8 = undefined;
    const status = json_string(body, "\"status\":", &status_buffer) orelse return error.Invalid;

    if (!std.mem.eql(u8, status, "success")) return error.Invalid;

    const offset_seconds = json_int(body, "\"offset\":") orelse return error.Invalid;

    var country_buffer: [2]u8 = .{ '?', '?' };
    _ = json_string(body, "\"countryCode\":", &country_buffer);

    state.offset_minutes = std.math.clamp(@as(i32, @intCast(@divTrunc(offset_seconds, 60))), -12 * 60, 14 * 60);
    state.country = country_buffer;
    state.ready = true;

}

/// Minimal JSON int extractor for a known small response shape.
fn json_int(body: []const u8, key: []const u8) ?i64 {

    const at = std.mem.indexOf(u8, body, key) orelse return null;
    const rest = body[at + key.len ..];

    var end: usize = 0;

    while (end < rest.len and (rest[end] == '-' or (rest[end] >= '0' and rest[end] <= '9'))) : (end += 1) {}

    if (end == 0) return null;

    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;

}

/// Scans for `"key":"value"` and copies up to `out.len` bytes of `value` into `out`, returning the copied slice.
fn json_string(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {

    const at = std.mem.indexOf(u8, body, key) orelse return null;
    const rest = body[at + key.len ..];

    if (rest.len == 0 or rest[0] != '"') return null;

    const value = rest[1..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    const length = @min(end, out.len);

    @memcpy(out[0..length], value[0..length]);

    return out[0..length];

}

fn dispatch(_: u64, method: u64, _: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.metrics.get_timezone => get_timezone(out),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.metrics.interface_id;
    out.data[2] = proto.metrics.version;

    return 0;

}

fn get_timezone(out: *Message) i64 {

    out.data[1] = if (state.ready) proto.metrics.status_ready else proto.metrics.status_unavailable;
    out.data[2] = @bitCast(@as(i64, state.offset_minutes));
    out.data[3] = (@as(u64, state.country[0]) << 8) | state.country[1];

    return 0;

}
