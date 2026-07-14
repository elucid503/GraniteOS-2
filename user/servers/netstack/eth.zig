// Ethernet framing.

const config = @import("config.zig");
const link = @import("link.zig");
const wire = @import("wire.zig");

pub const header_len = 14;

pub const ethertype_ipv4: u16 = 0x0800;
pub const ethertype_arp: u16 = 0x0806;

pub const broadcast: [6]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

pub const Parsed = struct {

    src_mac: [6]u8,
    dest_mac: [6]u8,
    ethertype: u16,

    payload: []const u8,

};

pub fn parse(frame: []const u8) ?Parsed {

    if (frame.len < header_len) return null;

    return .{

        .dest_mac = frame[0..6].*,
        .src_mac = frame[6..12].*,
        .ethertype = wire.get16(frame, 12),

        .payload = frame[header_len..],

    };

}

/// Build one Ethernet frame around `payload` and hand it to the driver.
pub fn send(dest_mac: [6]u8, ethertype: u16, payload: []const u8) void {

    var buffer: [@import("lib").netframe.max_frame]u8 = undefined;

    if (header_len + payload.len > buffer.len) return;

    @memcpy(buffer[0..6], &dest_mac);
    @memcpy(buffer[6..12], &config.mac);
    wire.put16(&buffer, 12, ethertype);
    @memcpy(buffer[header_len .. header_len + payload.len], payload);

    link.send_frame(buffer[0 .. header_len + payload.len]);

}
