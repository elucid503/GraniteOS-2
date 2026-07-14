// ICMP echo: answers `ping <guest-ip>`

const ip = @import("ip.zig");
const wire = @import("wire.zig");

const netaddr = @import("lib").netaddr;

const type_echo_request: u8 = 8;
const type_echo_reply: u8 = 0;

const max_message = 1400;

pub fn handle(src_ip: u32, payload: []const u8) void {

    if (payload.len < 8 or payload.len > max_message) return;
    if (payload[0] != type_echo_request) return;

    var buffer: [max_message]u8 = undefined;
    const length = payload.len;

    @memcpy(buffer[0..length], payload);

    buffer[0] = type_echo_reply;
    buffer[1] = 0;
    wire.put16(&buffer, 2, 0);
    wire.put16(&buffer, 2, netaddr.checksum(0, buffer[0..length]));

    ip.send(src_ip, ip.protocol_icmp, buffer[0..length]);

}
