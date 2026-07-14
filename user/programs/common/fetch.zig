// fetch: a minimal HTTP/1.0 client demonstrating a real TCP round trip over the netstack

const std = @import("std");

const lib = @import("lib");

comptime {

    _ = lib.start;

}

const Request = struct {

    host: []const u8,
    port: u16,
    path: []const u8,

};

/// Accepts either `fetch <url>` or the older `fetch <host> <port> [path]` form.
fn build_request(args: []const []const u8) ?Request {

    if (args.len == 2) {

        const url = lib.url.parse(args[1]) orelse return null;

        return .{ .host = url.host, .port = url.port, .path = url.path };

    }

    if (args.len < 3) return null;

    const port = std.fmt.parseInt(u16, args[2], 10) catch return null;
    const path = if (args.len > 3) args[3] else "/";

    return .{ .host = args[1], .port = port, .path = path };

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

    var socket = lib.net.Socket.connect_host(lib.cap.memory, request.host, request.port) catch |failure| {

        lib.io.print(out, "fetch: connect failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

    defer socket.close();

    var request_buffer: [512]u8 = undefined;
    const http_request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ request.path, request.host }) catch {

        lib.io.writeln(out, "fetch: request too long") catch {};

        return 1;

    };

    socket.send_all(http_request) catch |failure| {

        lib.io.print(out, "fetch: send failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

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
