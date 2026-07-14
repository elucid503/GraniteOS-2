// TCP socket client

const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");
const netaddr = @import("addr.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const buffer_size = 65536;

pub const Socket = struct {

    endpoint: Handle,
    buffer: Handle,
    readiness: Handle,

    base: usize,
    sid: u64,

    /// Resolve "netstack". Opens a stream socket and connects it to the given address and port, blocking until the connection is established or fails.
    pub fn connect(authority: Handle, addr: u32, port: u16) Error!Socket {

        var socket = try open(try stream.lookup_endpoint("netstack"), authority);

        errdefer socket.close();

        return finish_connect(socket, addr, port);

    }

    /// Like `connect`, but takes a hostname and resolves it to an IPv4 address through netstack's DNS resolver.
    pub fn connect_host(authority: Handle, name: []const u8, port: u16) Error!Socket {

        if (netaddr.parse_ipv4(name)) |addr| return connect(authority, addr, port);

        var socket = try open(try stream.lookup_endpoint("netstack"), authority);

        errdefer socket.close();

        const addr = try socket.resolve(name);

        return finish_connect(socket, addr, port);

    }

    fn finish_connect(socket: Socket, addr: u32, port: u16) Error!Socket {

        var result = socket;

        _ = try ipc.request(result.endpoint, proto.socket.connect, &.{ result.sid, addr, port }, &.{});

        while (true) {

            const bits = try result.poll_bits();

            if (bits & proto.socket.err != 0) return error.Gone;
            if (bits & proto.socket.connected != 0) return result;

            _ = try sys.wait(result.readiness);

        }

    }

    /// Resolve `name` to an IPv4 address through netstack's DNS resolver, reusing this socket's already-attached session buffer and readiness Notification.
    pub fn resolve(self: *Socket, name: []const u8) Error!u32 {

        if (name.len > buffer_size) return error.Invalid;

        const dest: [*]u8 = @ptrFromInt(self.base);

        @memcpy(dest[0..name.len], name);

        while (true) {

            const reply = ipc.request(self.endpoint, proto.socket.resolve, &.{ 0, name.len }, &.{}) catch |failure| switch (failure) {

                error.WouldBlock => {

                    _ = try sys.wait(self.readiness);
                    continue;

                },

                else => return failure,

            };

            return @intCast(reply.data[1]);

        }

    }

    /// Share the session buffer with an already-resolved netstack endpoint and allocate one (as yet unconnected) stream socket.
    pub fn open(endpoint: Handle, authority: Handle) Error!Socket {

        const buffer = try sys.create(.region, buffer_size, authority);
        const base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);
        const readiness = try sys.create(.notification, 0, 0);

        _ = try ipc.request(endpoint, proto.socket.attach, &.{buffer_size}, &.{

            .{ .handle = buffer, .move = false },
            .{ .handle = readiness, .move = false },

        });

        const reply = try ipc.request(endpoint, proto.socket.open, &.{proto.socket.kind_stream}, &.{});

        return .{

            .endpoint = endpoint,
            .buffer = buffer,
            .readiness = readiness,

            .base = base,
            .sid = reply.data[1],

        };

    }

    /// Send up to `buffer_size` bytes, blocking while the send window is full; returns bytes actually queued.
    pub fn send(self: *Socket, bytes: []const u8) Error!usize {

        const amount = @min(bytes.len, buffer_size);

        if (amount == 0) return 0;

        const dest: [*]u8 = @ptrFromInt(self.base);

        @memcpy(dest[0..amount], bytes[0..amount]);

        while (true) {

            const reply = ipc.request(self.endpoint, proto.socket.send, &.{ self.sid, 0, amount }, &.{}) catch |failure| switch (failure) {

                error.WouldBlock => {

                    _ = try sys.wait(self.readiness);
                    continue;

                },

                else => return failure,

            };

            return @intCast(reply.data[1]);

        }

    }

    pub fn send_all(self: *Socket, bytes: []const u8) Error!void {

        var cursor: usize = 0;

        while (cursor < bytes.len) {

            const written = try self.send(bytes[cursor..]);

            if (written == 0) return error.Gone;

            cursor += written;

        }

    }

    /// Read up to `out.len` bytes, blocking until data (or the peer's FIN) arrives. Returns 0 only at true EOF.
    pub fn recv(self: *Socket, out: []u8) Error!usize {

        const amount = @min(out.len, buffer_size);

        while (true) {

            const reply = ipc.request(self.endpoint, proto.socket.recv, &.{ self.sid, 0, amount }, &.{}) catch |failure| switch (failure) {

                error.WouldBlock => {

                    _ = try sys.wait(self.readiness);
                    continue;

                },

                else => return failure,

            };

            const length: usize = @intCast(reply.data[1]);

            if (length == 0) return 0;

            const source: [*]const u8 = @ptrFromInt(self.base);

            @memcpy(out[0..length], source[0..length]);

            return length;

        }

    }

    fn poll_bits(self: *Socket) Error!u64 {

        const reply = try ipc.request(self.endpoint, proto.socket.poll, &.{self.sid}, &.{});

        return reply.data[1];

    }

    pub fn close(self: *Socket) void {

        _ = ipc.request(self.endpoint, proto.socket.close, &.{self.sid}, &.{}) catch {};
        _ = ipc.request(self.endpoint, proto.socket.detach, &.{}, &.{}) catch {};

        sys.unmap(cap.self_space, self.base) catch {};
        sys.close(self.buffer) catch {};
        sys.close(self.readiness) catch {};
        sys.close(self.endpoint) catch {};

    }

};
