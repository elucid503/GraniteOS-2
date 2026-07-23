// Thin net-driver status client: link up/down, byte counters, software enable.

const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

pub const Status = struct {

    up: bool,
    enabled: bool,
    rx_bytes: u64,
    tx_bytes: u64,

};

pub fn status() ?Status {

    const endpoint = stream.lookup_endpoint("net") catch return null;
    defer sys.close(endpoint) catch {};

    const reply = ipc.request(endpoint, proto.net.link_status, &.{}, &.{}) catch return null;

    return .{

        .up = reply.data[1] != 0,
        .rx_bytes = reply.data[2],
        .tx_bytes = reply.data[3],
        .enabled = reply.data[4] != 0,

    };

}

pub fn set_enabled(value: bool) void {

    const endpoint = stream.lookup_endpoint("net") catch return;
    defer sys.close(endpoint) catch {};

    _ = ipc.request(endpoint, proto.net.set_enabled, &.{@intFromBool(value)}, &.{}) catch {};

}
