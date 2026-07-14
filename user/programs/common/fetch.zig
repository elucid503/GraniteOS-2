// fetch: a minimal HTTP/1.0 client demonstrating a real TCP round trip over the netstack

const std = @import("std");

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 3) {

        lib.io.writeln(out, "usage: fetch <ip> <port> [path]") catch {};

        return 1;

    }

    const addr = lib.netaddr.parse_ipv4(args[1]) orelse {

        lib.io.writeln(out, "fetch: invalid IPv4 address") catch {};

        return 1;

    };

    const port = std.fmt.parseInt(u16, args[2], 10) catch {

        lib.io.writeln(out, "fetch: invalid port") catch {};

        return 1;

    };

    const path = if (args.len > 3) args[3] else "/";

    var socket = lib.net.Socket.connect(lib.cap.memory, addr, port) catch |failure| {

        lib.io.print(out, "fetch: connect failed: {s}\n", .{@errorName(failure)}) catch {};

        return 1;

    };

    defer socket.close();

    var request_buffer: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, args[1] }) catch {

        lib.io.writeln(out, "fetch: request too long") catch {};

        return 1;

    };

    socket.send_all(request) catch |failure| {

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
