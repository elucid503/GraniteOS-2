// Stream abstraction for console-backed endpoints and M6 peer-to-peer rings.

const std = @import("std");

const cap = @import("cap.zig");
const ipc = @import("ipc.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const page_size = 4096;
const buffer_size = 4096;
const data_bit: u64 = 1;
const space_bit: u64 = 2;

pub const Stream = struct {

    backing: Backing,

    pub fn read(self: *Stream, buf: []u8) Error!usize {

        return switch (self.backing) {

            .server => |*server_stream| server_stream.read(buf),
            .ring => |*ring_stream| ring_stream.read(buf),

        };

    }

    pub fn write(self: *Stream, bytes: []const u8) Error!usize {

        return switch (self.backing) {

            .server => |*server_stream| server_stream.write(bytes),
            .ring => |*ring_stream| ring_stream.write(bytes),

        };

    }

    pub fn close(self: *Stream) void {

        switch (self.backing) {

            .server => {},
            .ring => |*ring_stream| ring_stream.close(),

        }

    }

};

const Backing = union(enum) {

    server: Server,
    ring: Ring,

};

const Server = struct {

    endpoint: Handle,
    buffer: Handle,
    base: usize,
    capacity: usize,

    fn open(endpoint: Handle, authority: Handle) Error!Server {

        const buffer = try sys.create(.region, buffer_size, authority);
        const base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);

        _ = try ipc.request(endpoint, proto.stream.attach, &.{buffer_size}, &.{

            .{ .handle = buffer, .move = false },

        });

        return .{

            .endpoint = endpoint,
            .buffer = buffer,
            .base = base,
            .capacity = buffer_size,

        };

    }

    fn read(self: *Server, buf: []u8) Error!usize {

        const amount = @min(buf.len, self.capacity);
        const reply = try ipc.request(self.endpoint, proto.stream.read, &.{ 0, amount }, &.{});
        const length: usize = @intCast(reply.data[0]);
        const source: [*]const u8 = @ptrFromInt(self.base);

        @memcpy(buf[0..length], source[0..length]);

        return length;

    }

    fn write(self: *Server, bytes: []const u8) Error!usize {

        const amount = @min(bytes.len, self.capacity);
        const destination: [*]u8 = @ptrFromInt(self.base);

        @memcpy(destination[0..amount], bytes[0..amount]);

        const reply = try ipc.request(self.endpoint, proto.stream.write, &.{ 0, amount }, &.{});

        return @intCast(reply.data[0]);

    }

};

const RingHeader = extern struct {

    head: u32,
    tail: u32,
    closed: u32,
    capacity: u32,

};

pub const Ring = struct {

    header: *volatile RingHeader,
    bytes: [*]u8,
    ready: Handle,

    pub const Pair = struct {

        region: Handle,
        ready: Handle,
        read: Stream,
        write: Stream,

    };

    pub fn create(authority: Handle, capacity: usize) Error!Pair {

        const total = @max(capacity + @sizeOf(RingHeader), page_size);
        const region = try sys.create(.region, total, authority);
        const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
        const ready = try sys.create(.notification, 0, 0);

        const header: *volatile RingHeader = @ptrFromInt(base);
        header.* = .{

            .head = 0,
            .tail = 0,
            .closed = 0,
            .capacity = @intCast(total - @sizeOf(RingHeader)),

        };

        const bytes: [*]u8 = @ptrFromInt(base + @sizeOf(RingHeader));

        return .{

            .region = region,
            .ready = ready,
            .read = .{ .backing = .{ .ring = .{ .header = header, .bytes = bytes, .ready = ready } } },
            .write = .{ .backing = .{ .ring = .{ .header = header, .bytes = bytes, .ready = ready } } },

        };

    }

    pub fn open(region: Handle, ready: Handle) Error!Ring {

        const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);

        return .{

            .header = @ptrFromInt(base),
            .bytes = @ptrFromInt(base + @sizeOf(RingHeader)),
            .ready = ready,

        };

    }

    fn read(self: *Ring, buf: []u8) Error!usize {

        while (available(self.header) == 0) {

            if (self.header.closed != 0) return 0;

            _ = try sys.wait(self.ready);

        }

        const amount = @min(buf.len, available(self.header));
        const capacity = self.header.capacity;

        for (0..amount) |index| {

            const offset = (@as(usize, self.header.head) + index) % @as(usize, capacity);

            buf[index] = self.bytes[offset];

        }

        self.header.head +%= @intCast(amount);
        try sys.notify(self.ready, space_bit);

        return amount;

    }

    fn write(self: *Ring, bytes: []const u8) Error!usize {

        var written: usize = 0;

        while (written < bytes.len) {

            while (free_space(self.header) == 0) {

                _ = try sys.wait(self.ready);

            }

            const amount = @min(bytes.len - written, free_space(self.header));
            const capacity = self.header.capacity;

            for (0..amount) |index| {

                const offset = (@as(usize, self.header.tail) + index) % @as(usize, capacity);

                self.bytes[offset] = bytes[written + index];

            }

            self.header.tail +%= @intCast(amount);
            written += amount;

            try sys.notify(self.ready, data_bit);

        }

        return written;

    }

    fn close(self: *Ring) void {

        self.header.closed = 1;
        sys.notify(self.ready, data_bit) catch {};

    }

};

pub fn server(endpoint: Handle, authority: Handle) Error!Stream {

    return .{ .backing = .{ .server = try Server.open(endpoint, authority) } };

}

pub fn ring(region: Handle, ready: Handle) Error!Stream {

    return .{ .backing = .{ .ring = try Ring.open(region, ready) } };

}

pub fn lookup(service: []const u8, authority: Handle) Error!Stream {

    const endpoint = try lookup_endpoint(service);

    return server(endpoint, authority);

}

pub fn lookup_endpoint(service: []const u8) Error!Handle {

    const message = try name_request(cap.name_service, proto.name.lookup, service, &.{});

    if (message.handle_count < 1) return error.NotFound;

    return message.handles[0].handle;

}

pub fn register_name(service: []const u8, endpoint: Handle) Error!void {

    try register_with(cap.name_service, service, endpoint);

}

pub fn register_with(naming: Handle, service: []const u8, endpoint: Handle) Error!void {

    _ = try name_request(naming, proto.name.register, service, &.{

        .{ .handle = endpoint, .move = false },

    });

}

fn name_request(naming: Handle, method: u16, name: []const u8, handles: []const ipc.HandleSlot) Error!ipc.Message {

    if (name.len > proto.name.max_length) return error.Invalid;

    var words = [_]u64{0} ** 5;
    words[0] = name.len;

    var inline_name = [_]u8{0} ** proto.name.max_length;
    @memcpy(inline_name[0..name.len], name);

    for (0..4) |index| {

        words[index + 1] = std.mem.readInt(u64, inline_name[index * 8 ..][0..8], .little);

    }

    return ipc.request(naming, method, &words, handles);

}

fn available(header: *volatile RingHeader) usize {

    return @intCast(header.tail -% header.head);

}

fn free_space(header: *volatile RingHeader) usize {

    return @as(usize, header.capacity) - available(header) - 1;

}

test "ring arithmetic wraps and leaves one byte empty" {

    var header = RingHeader{

        .head = 14,
        .tail = 18,
        .closed = 0,
        .capacity = 16,

    };

    try std.testing.expectEqual(@as(usize, 4), available(&header));
    try std.testing.expectEqual(@as(usize, 11), free_space(&header));

}
