// Small HTTP/1.0 client over plain TCP or TLS.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const mem = @import("../mem/mem.zig");
const sys = @import("../syscall/sys.zig");
const net = @import("net.zig");
const url_mod = @import("url.zig");
const tls = @import("../tls/session.zig");

const Handle = cap.Handle;

pub const Error = error{
    Invalid,
    InvalidResponse,
    Truncated,
    ResponseTooLarge,
    WriteFailed,
    ReadFailed,
    Gone,
    OutOfMemory,
    Timeout,
} || tls.Error || sys.Error;

pub const Header = struct {

    name: []const u8,
    value: []const u8,

};

pub const Request = struct {

    method: []const u8 = "GET",
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",

};

pub const Response = struct {

    status: u16,
    headers: []const u8,
    body: []const u8,

    pub fn header(self: Response, name: []const u8) ?[]const u8 {

        var lines = std.mem.splitSequence(u8, self.headers, "\r\n");

        while (lines.next()) |line| {

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const candidate = std.mem.trim(u8, line[0..colon], " \t");

            if (!std.ascii.eqlIgnoreCase(candidate, name)) continue;

            return std.mem.trim(u8, line[colon + 1 ..], " \t");

        }

        return null;

    }

    pub fn content_length(self: Response) ?usize {

        const value = self.header("content-length") orelse return null;

        return std.fmt.parseInt(usize, value, 10) catch null;

    }

};

pub const Connection = struct {

    kind: enum {

        plain,
        secure,

    },

    socket: net.Socket,
    session: tls.Session,

    pub fn connect_host(
        out: *Connection,
        authority: Handle,
        heap: *mem.Heap,
        host: []const u8,
        port: u16,
        secure: bool,
    ) !void {

        if (secure) {

            out.kind = .secure;
            try tls.Session.connect_host(&out.session, authority, heap, host, port);

        } else {

            out.kind = .plain;
            out.socket = try net.Socket.connect_host(authority, host, port);

        }

    }

    pub fn send_all(self: *Connection, bytes: []const u8) !void {

        switch (self.kind) {

            .plain => try self.socket.send_all(bytes),
            .secure => try self.session.send_all(bytes),

        }

    }

    pub fn recv(self: *Connection, out: []u8) !usize {

        return switch (self.kind) {

            .plain => try self.socket.recv(out),
            .secure => try self.session.recv(out),

        };

    }

    pub fn close(self: *Connection) void {

        switch (self.kind) {

            .plain => self.socket.close(),
            .secure => self.session.close(),

        }

    }

};

/// Send one HTTP/1.0 request and collect its response in `response_buffer`.
pub fn request(
    authority: Handle,
    heap: *mem.Heap,
    options: Request,
    response_buffer: []u8,
) !Response {

    const parsed = url_mod.parse(options.url) orelse return error.Invalid;

    if (!valid_token(options.method)) return error.Invalid;

    var head_buffer: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&head_buffer);
    const writer = stream.writer();

    try writer.print("{s} {s} HTTP/1.0\r\nHost: {s}", .{ options.method, parsed.path, parsed.host });

    if (parsed.port != 80 and parsed.port != 443) try writer.print(":{d}", .{parsed.port});

    try writer.writeAll("\r\nConnection: close\r\n");

    for (options.headers) |header| {

        if (!valid_token(header.name) or contains_newline(header.value)) return error.Invalid;

        try writer.print("{s}: {s}\r\n", .{ header.name, header.value });

    }

    if (options.body.len != 0) try writer.print("Content-Length: {d}\r\n", .{options.body.len});

    try writer.writeAll("\r\n");

    var connection: Connection = undefined;

    try Connection.connect_host(
        &connection,
        authority,
        heap,
        parsed.host,
        parsed.port,
        url_mod.is_tls(parsed.scheme),
    );
    defer connection.close();

    try connection.send_all(stream.getWritten());

    if (options.body.len != 0) try connection.send_all(options.body);

    const length = try read_all(&connection, response_buffer);

    return parse_response(response_buffer[0..length]);

}

/// Collect and parse the response from an already-connected request.
pub fn receive_response(connection: *Connection, response_buffer: []u8) !Response {

    const length = try read_all(connection, response_buffer);

    return parse_response(response_buffer[0..length]);

}

/// Parse a complete HTTP response already held in memory.
pub fn parse_response(payload: []const u8) !Response {

    const header_end = std.mem.indexOf(u8, payload, "\r\n\r\n") orelse return error.InvalidResponse;
    const first_line_end = std.mem.indexOf(u8, payload[0..header_end], "\r\n") orelse return error.InvalidResponse;
    const status_line = payload[0..first_line_end];

    const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidResponse;
    const after_protocol = status_line[first_space + 1 ..];
    const second_space = std.mem.indexOfScalar(u8, after_protocol, ' ') orelse after_protocol.len;
    const status_text = after_protocol[0..second_space];

    if (status_text.len != 3) return error.InvalidResponse;

    const status = std.fmt.parseInt(u16, status_text, 10) catch return error.InvalidResponse;

    return .{

        .status = status,
        .headers = payload[first_line_end + 2 .. header_end],
        .body = payload[header_end + 4 ..],

    };

}

/// GET `url_text` into `response`. Returns total bytes written (headers + body).
pub fn get(
    authority: Handle,
    heap: *mem.Heap,
    url_text: []const u8,
    response: []u8,
) !usize {

    const parsed = url_mod.parse(url_text) orelse return error.Invalid;
    const use_tls = url_mod.is_tls(parsed.scheme);

    var request_buffer: [512]u8 = undefined;
    const host_header = try format_host_header(parsed.host, parsed.port, &request_buffer);
    // host_header reuses request_buffer prefix; rebuild request after.
    var host_copy: [256]u8 = undefined;

    if (host_header.len > host_copy.len) return error.Invalid;

    @memcpy(host_copy[0..host_header.len], host_header);
    const host_h = host_copy[0..host_header.len];

    const http_request = std.fmt.bufPrint(
        &request_buffer,
        "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{ parsed.path, host_h },
    ) catch return error.Invalid;

    if (use_tls) {

        var session: tls.Session = undefined;

        try tls.Session.connect_host(&session, authority, heap, parsed.host, parsed.port);
        defer session.close();

        try session.send_all(http_request);

        return read_all_tls(&session, response);

    } else {

        var socket = try net.Socket.connect_host(authority, parsed.host, parsed.port);
        defer socket.close();

        try socket.send_all(http_request);

        return read_all_socket(&socket, response);

    }

}

fn format_host_header(host: []const u8, port: u16, scratch: []u8) ![]const u8 {

    if (port == 80 or port == 443) return host;

    return std.fmt.bufPrint(scratch, "{s}:{d}", .{ host, port }) catch return error.Invalid;

}

fn read_all_socket(socket: *net.Socket, response: []u8) !usize {

    var total: usize = 0;

    while (total < response.len) {

        const n = try socket.recv(response[total..]);

        if (n == 0) break;

        total += n;

        if (try complete_length(response[0..total])) |expected| {

            if (expected > response.len) return error.ResponseTooLarge;
            if (total >= expected) return expected;

        }

    }

    try check_content_length(response[0..total]);

    return total;

}

fn read_all_tls(session: *tls.Session, response: []u8) !usize {

    var total: usize = 0;

    while (total < response.len) {

        const n = try session.recv(response[total..]);

        if (n == 0) break;

        total += n;

        if (try complete_length(response[0..total])) |expected| {

            if (expected > response.len) return error.ResponseTooLarge;
            if (total >= expected) return expected;

        }

    }

    try check_content_length(response[0..total]);

    return total;

}

fn read_all(connection: *Connection, response: []u8) !usize {

    var total: usize = 0;

    while (total < response.len) {

        const n = try connection.recv(response[total..]);

        if (n == 0) break;

        total += n;

        if (try complete_length(response[0..total])) |expected| {

            if (expected > response.len) return error.ResponseTooLarge;
            if (total >= expected) return expected;

        }

    }

    if (total == response.len) {

        var extra: [1]u8 = undefined;

        if (try connection.recv(&extra) != 0) return error.ResponseTooLarge;

    }

    try check_content_length(response[0..total]);

    return total;

}

fn complete_length(payload: []const u8) !?usize {

    const header_end = std.mem.indexOf(u8, payload, "\r\n\r\n") orelse return null;
    const parsed = try parse_response(payload[0 .. header_end + 4]);
    const body_length = parsed.content_length() orelse return null;

    return std.math.add(usize, header_end + 4, body_length) catch error.ResponseTooLarge;

}

fn valid_token(text: []const u8) bool {

    if (text.len == 0) return false;

    for (text) |byte| {

        if (byte <= 32 or byte >= 127 or byte == ':' or byte == '\\') return false;

    }

    return true;

}

fn contains_newline(text: []const u8) bool {

    return std.mem.indexOfScalar(u8, text, '\r') != null or std.mem.indexOfScalar(u8, text, '\n') != null;

}

fn check_content_length(payload: []const u8) !void {

    const header_end = std.mem.indexOf(u8, payload, "\r\n\r\n") orelse return;
    const headers = payload[0..header_end];
    const body = payload[header_end + 4 ..];

    var iter = std.mem.splitSequence(u8, headers, "\r\n");

    _ = iter.next(); // status line

    while (iter.next()) |line| {

        if (line.len >= 15 and std.ascii.eqlIgnoreCase(line[0..14], "content-length")) {

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            const expected = std.fmt.parseInt(usize, value, 10) catch continue;

            if (body.len != expected) return error.Truncated;

            return;

        }

    }

}

const testing = std.testing;

test "parses response status headers and body" {

    const parsed = try parse_response("HTTP/1.0 202 Accepted\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}");

    try testing.expectEqual(@as(u16, 202), parsed.status);
    try testing.expectEqualStrings("Content-Type: application/json", parsed.headers);
    try testing.expectEqualStrings("{\"ok\":true}", parsed.body);
    try testing.expectEqualStrings("application/json", parsed.header("content-type").?);
    try testing.expectEqual(@as(?[]const u8, null), parsed.header("location"));
    try testing.expectEqual(@as(?usize, null), parsed.content_length());

    const sized = try parse_response("HTTP/1.0 200 OK\r\ncontent-length: 42\r\n\r\n");

    try testing.expectEqual(@as(?usize, 42), sized.content_length());

}

test "computes a complete response length before EOF" {

    const payload = "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhelloignored";
    const expected = (try complete_length(payload)).?;

    try testing.expectEqual(payload.len - "ignored".len, expected);

}

test "rejects malformed response" {

    try testing.expectError(error.InvalidResponse, parse_response("not http"));
    try testing.expectError(error.InvalidResponse, parse_response("HTTP/1.0 nope\r\n\r\n"));

}
