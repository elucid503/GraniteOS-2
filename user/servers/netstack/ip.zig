// IPv4: header parse/build/checksum and MAC resolution for outbound datagrams.

const eth = @import("eth.zig");
const arp = @import("arp.zig");
const config = @import("config.zig");
const wire = @import("wire.zig");

const netaddr = @import("lib").netaddr;

pub const protocol_icmp: u8 = 1;
pub const protocol_tcp: u8 = 6;
pub const protocol_udp: u8 = 17;

const header_len = 20;
const default_ttl: u8 = 64;
pub const max_payload = @import("lib").netframe.max_frame - eth.header_len - header_len;

pub const Parsed = struct {

    src_ip: u32,
    dst_ip: u32,
    protocol: u8,

    payload: []const u8,

};

pub fn parse(bytes: []const u8) ?Parsed {

    if (bytes.len < header_len) return null;

    const version = bytes[0] >> 4;
    const ihl: usize = @as(usize, bytes[0] & 0x0f) * 4;

    if (version != 4 or ihl < header_len or ihl > bytes.len) return null;
    if (netaddr.checksum(0, bytes[0..ihl]) != 0) return null;

    // No reassembly. MF set or a nonzero offset is dropped outright rather than mishandled.

    const flags_and_offset = wire.get16(bytes, 6);

    if (flags_and_offset & 0x2000 != 0 or flags_and_offset & 0x1fff != 0) return null;

    const total_length: usize = wire.get16(bytes, 2);

    if (total_length < ihl or total_length > bytes.len) return null;

    return .{

        .src_ip = wire.get32(bytes, 12),
        .dst_ip = wire.get32(bytes, 16),
        .protocol = bytes[9],

        .payload = bytes[ihl..total_length],

    };

}

/// Build one IPv4 datagram around `payload` and hand it down to Ethernet.
pub fn send(dest_ip: u32, protocol: u8, payload: []const u8) void {

    if (payload.len > max_payload) return;

    const next_hop = config.next_hop(dest_ip);
    const mac = arp.resolve(next_hop) orelse {

        arp.request(next_hop);
        return;

    };

    var buffer: [header_len + max_payload]u8 = undefined;
    const total_length = header_len + payload.len;

    buffer[0] = 0x45; // version 4, IHL 5 (no options)
    buffer[1] = 0; // DSCP/ECN
    wire.put16(&buffer, 2, @intCast(total_length));
    wire.put16(&buffer, 4, 0); // identification: fine to leave at 0 - we never fragment
    wire.put16(&buffer, 6, 0); // flags/fragment offset: none
    buffer[8] = default_ttl;
    buffer[9] = protocol;
    wire.put16(&buffer, 10, 0); // checksum, filled below
    wire.put32(&buffer, 12, config.ip);
    wire.put32(&buffer, 16, dest_ip);

    wire.put16(&buffer, 10, netaddr.checksum(0, buffer[0..header_len]));

    @memcpy(buffer[header_len..total_length], payload);

    eth.send(mac, eth.ethertype_ipv4, buffer[0..total_length]);

}
