// The netstack's one connection to the virtio-net driver.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const config = @import("config.zig");

const rx_capacity: u32 = 64;
const tx_capacity: usize = lib.netframe.max_frame;

var net_endpoint: cap.Handle = 0;
var rx_ring: lib.netframe.Ring = undefined;
var tx_base: usize = 0;

/// `wake` is the reactor's single merged notification.
pub fn attach(endpoint: cap.Handle, authority: cap.Handle, wake: cap.Handle) !void {

    net_endpoint = endpoint;

    const bytes = lib.netframe.ring_bytes(rx_capacity);
    const ring_region = try sys.create(.region, bytes, authority);
    const ring_base = try sys.map(cap.self_space, ring_region, 0, sys.read | sys.write);

    rx_ring = lib.netframe.Ring.init(ring_base, rx_capacity);

    const tx_region = try sys.create(.region, tx_capacity, authority);

    tx_base = try sys.map(cap.self_space, tx_region, 0, sys.read | sys.write);

    _ = try ipc.request(net_endpoint, proto.net.attach, &.{ rx_capacity, tx_capacity }, &.{

        .{ .handle = ring_region, .move = false },
        .{ .handle = tx_region, .move = false },
        .{ .handle = wake, .move = false },

    });

    sys.close(ring_region) catch {};
    sys.close(tx_region) catch {};

    const reply = try ipc.request(net_endpoint, proto.net.mac_address, &.{}, &.{});
    const low = reply.data[1];
    const high = reply.data[2];

    config.mac = .{

        @truncate(low), @truncate(low >> 8),
        @truncate(low >> 16), @truncate(low >> 24),
        @truncate(high), @truncate(high >> 8),

    };

}

/// Drain every frame currently in the RX ring, handing each to `handler` in arrival order.
pub fn drain(handler: *const fn ([]const u8) void) void {

    var buffer: [lib.netframe.max_frame]u8 = undefined;

    while (rx_ring.pop(&buffer)) |length| {

        handler(buffer[0..length]);

    }

}

/// Best-effort transmit: failures (driver gone, oversized frame) are silently dropped.
pub fn send_frame(bytes: []const u8) void {

    if (bytes.len == 0 or bytes.len > tx_capacity or tx_base == 0) return;

    const dest: [*]u8 = @ptrFromInt(tx_base);

    @memcpy(dest[0..bytes.len], bytes);

    _ = ipc.request(net_endpoint, proto.net.transmit, &.{bytes.len}, &.{}) catch {};

}
