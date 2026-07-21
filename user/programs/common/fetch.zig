// fetch: HTTP/1.0 and HTTPS GET over the netstack (+ TLS when scheme is https)

const std = @import("std");

const lib = @import("lib");

pub const std_options = lib.rng.std_options;

comptime {

    _ = lib.start;

}

const Request = struct {

    host: []const u8,
    port: u16,
    path: []const u8,
    use_tls: bool,

};

/// Accepts either `fetch <url>` or the older `fetch <host> <port> [path]` form.
fn build_request(args: []const []const u8) ?Request {

    if (args.len == 2) {

        const url = lib.url.parse(args[1]) orelse return null;

        return .{

            .host = url.host,
            .port = url.port,
            .path = url.path,
            .use_tls = lib.url.is_tls(url.scheme),

        };

    }

    if (args.len < 3) return null;

    const port = std.fmt.parseInt(u16, args[2], 10) catch return null;
    const path = if (args.len > 3) args[3] else "/";

    return .{ .host = args[1], .port = port, .path = path, .use_tls = false };

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 2) {

        lib.io.writeln(out, "usage: fetch <url> | fetch <host> <port> [path]") catch {};

        return 1;

    }

    const request = build_request(args) orelse {

        lib.io.writeln(out, "fetch: invalid arguments") catch {};

        return 1;

    };

    var heap = lib.mem.Heap.init(lib.cap.memory);

    if (request.use_tls) {

        return fetch_https(out, &heap, request);

    }

    return fetch_http(out, request);

}

fn fetch_http(out: anytype, request: Request) u8 {

    var socket = lib.net.Socket.connect_host(lib.cap.memory, request.host, request.port) catch |failure| {

        lib.io.print(out, "fetch: connect failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

    defer socket.close();

    var request_buffer: [512]u8 = undefined;
    const host_header = host_header_for(request.host, request.port, &request_buffer) orelse request.host;
    var host_copy: [256]u8 = undefined;

    if (host_header.len > host_copy.len) {

        lib.io.writeln(out, "fetch: host too long") catch {};

        return 1;

    }

    @memcpy(host_copy[0..host_header.len], host_header);

    const http_request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{

        request.path,
        host_copy[0..host_header.len],

    }) catch {

        lib.io.writeln(out, "fetch: request too long") catch {};

        return 1;

    };

    socket.send_all(http_request) catch |failure| {

        lib.io.print(out, "fetch: send failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

    return pump_socket(out, &socket);

}

fn fetch_https(out: anytype, heap: *lib.mem.Heap, request: Request) u8 {

    var session: lib.tls.Session = undefined;

    lib.tls.Session.connect_host(&session, lib.cap.memory, heap, request.host, request.port) catch |failure| {

        lib.io.print(out, "fetch: tls connect failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

    defer session.close();

    var request_buffer: [512]u8 = undefined;
    const host_header = host_header_for(request.host, request.port, &request_buffer) orelse request.host;
    var host_copy: [256]u8 = undefined;

    if (host_header.len > host_copy.len) {

        lib.io.writeln(out, "fetch: host too long") catch {};

        return 1;

    }

    @memcpy(host_copy[0..host_header.len], host_header);

    const http_request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{

        request.path,
        host_copy[0..host_header.len],

    }) catch {

        lib.io.writeln(out, "fetch: request too long") catch {};

        return 1;

    };

    session.send_all(http_request) catch |failure| {

        lib.io.print(out, "fetch: send failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

    return pump_tls(out, &session);

}

fn host_header_for(host: []const u8, port: u16, scratch: []u8) ?[]const u8 {

    if (port == 80 or port == 443) return host;

    return std.fmt.bufPrint(scratch, "{s}:{d}", .{ host, port }) catch null;

}

fn pump_socket(out: anytype, socket: *lib.net.Socket) u8 {

    var buffer: [4096]u8 = undefined;

    while (true) {

        const length = socket.recv(&buffer) catch |failure| {

            lib.io.print(out, "\nfetch: recv failed: {s}\n", .{@errorName(failure)}) catch {};

            return 1;

        };

        if (length == 0) break;

        lib.io.write(out, buffer[0..length]) catch break;

    }

    return 0;

}

fn pump_tls(out: anytype, session: *lib.tls.Session) u8 {

    var buffer: [4096]u8 = undefined;

    while (true) {

        const length = session.recv(&buffer) catch |failure| {

            lib.io.print(out, "\nfetch: recv failed: {s}\n", .{@errorName(failure)}) catch {};

            return 1;

        };

        if (length == 0) break;

        lib.io.write(out, buffer[0..length]) catch break;

    }

    return 0;

}
