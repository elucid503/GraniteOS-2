// UDP: internal only, not client-facing (07-userspace-ddd.md style).

const ip = @import("ip.zig");
const wire = @import("wire.zig");
const config = @import("config.zig");

const netaddr = @import("lib").netaddr;

const header_len = 8;
const max_payload = ip.max_payload - header_len;
const max_registrations = 4;

pub const Handler = *const fn (src_ip: u32, src_port: u16, payload: []const u8) void;

const Registration = struct {

    used: bool = false,
    port: u16 = 0,
    handler: Handler = undefined,

};

var registrations: [max_registrations]Registration = [_]Registration{.{}} ** max_registrations;

/// Claim `port`: datagrams addressed to it are handed to `handler`. One registrant per port.
pub fn register(port: u16, handler: Handler) void {

    for (&registrations) |*reg| {

        if (!reg.used) {

            reg.* = .{ .used = true, .port = port, .handler = handler };
            return;

        }

    }

}

pub fn send(dest_ip: u32, dest_port: u16, src_port: u16, payload: []const u8) void {

    if (payload.len > max_payload) return;

    var buffer: [header_len + max_payload]u8 = undefined;
    const total = header_len + payload.len;

    wire.put16(&buffer, 0, src_port);
    wire.put16(&buffer, 2, dest_port);
    wire.put16(&buffer, 4, @intCast(total));
    wire.put16(&buffer, 6, 0); // checksum, filled below

    @memcpy(buffer[header_len..total], payload);

    var pseudo: [12]u8 = undefined;

    wire.put32(&pseudo, 0, config.ip);
    wire.put32(&pseudo, 4, dest_ip);
    pseudo[8] = 0;
    pseudo[9] = ip.protocol_udp;
    wire.put16(&pseudo, 10, @intCast(total));

    const seed = netaddr.checksum_seed(0, &pseudo);

    wire.put16(&buffer, 6, netaddr.finish(netaddr.checksum_seed(seed, buffer[0..total])));

    ip.send(dest_ip, ip.protocol_udp, buffer[0..total]);

}

pub fn handle(src_ip: u32, dst_ip: u32, payload: []const u8) void {

    if (dst_ip != config.ip) return;
    if (payload.len < header_len) return;

    const length: usize = wire.get16(payload, 4);

    if (length < header_len or length > payload.len) return;

    const checksum = wire.get16(payload, 6);

    if (checksum != 0 and !verify_checksum(src_ip, dst_ip, payload[0..length])) return;

    const src_port = wire.get16(payload, 0);
    const dst_port = wire.get16(payload, 2);
    const data = payload[header_len..length];

    for (&registrations) |*reg| {

        if (reg.used and reg.port == dst_port) {

            reg.handler(src_ip, src_port, data);
            return;

        }

    }

}

fn verify_checksum(src_ip: u32, dst_ip: u32, segment: []const u8) bool {

    var pseudo: [12]u8 = undefined;

    wire.put32(&pseudo, 0, src_ip);
    wire.put32(&pseudo, 4, dst_ip);
    pseudo[8] = 0;
    pseudo[9] = ip.protocol_udp;
    wire.put16(&pseudo, 10, @intCast(segment.len));

    const seed = netaddr.checksum_seed(0, &pseudo);

    return netaddr.finish(netaddr.checksum_seed(seed, segment)) == 0;

}
