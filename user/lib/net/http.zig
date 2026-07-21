// Thin HTTP/1.0 GET over plain TCP or TLS.

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
    Truncated,
    ResponseTooLarge,
    WriteFailed,
    ReadFailed,
    Gone,
    OutOfMemory,

} || tls.Error || sys.Error;

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

    }

    try check_content_length(response[0..total]);

    return total;

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
