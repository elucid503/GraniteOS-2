// Minimal SNTP client (RFC 5905) over internal UDP — corrects wall_offset for PKI.

const lib = @import("lib");

const udp = @import("udp.zig");
const wire = @import("wire.zig");
const config = @import("config.zig");

// time.google.com 216.239.35.0 and Cloudflare 162.159.200.1 as fixed NTP peers.
const peers = [_]u32{ 0xd8ef_2300, 0xa29f_c801 };

const ntp_port: u16 = 123;
const local_port: u16 = 53211;
const packet_len = 48;
const unix_epoch_delta: i64 = 2_208_988_800; // seconds between 1900 and 1970

var offset_s: i64 = 0;
var synced: bool = false;
var pending: bool = false;
var next_try_ms: u64 = 0;
var peer_index: usize = 0;

pub fn init() void {

    udp.register(local_port, handle_response);

}

pub fn offset() i64 {

    return offset_s;

}

pub fn is_synced() bool {

    return synced;

}

pub fn tick(now_ms: u64) void {

    if (synced) return;
    if (now_ms < next_try_ms) return;

    next_try_ms = now_ms + 5_000;

    var packet: [packet_len]u8 = .{0} ** packet_len;

    // LI=0, VN=4, Mode=3 (client)
    packet[0] = 0x23;

    const peer = peers[peer_index % peers.len];

    peer_index +%= 1;
    pending = true;

    udp.send(peer, ntp_port, local_port, &packet);

}

fn handle_response(src_ip: u32, src_port: u16, payload: []const u8) void {

    _ = src_ip;

    if (src_port != ntp_port) return;
    if (payload.len < packet_len) return;
    if (!pending) return;

    // Transmit Timestamp seconds at offset 40 (big-endian).
    const ntp_sec = wire.get32(payload, 40);

    if (ntp_sec < unix_epoch_delta) return;

    const remote_unix: i64 = @intCast(ntp_sec -% @as(u32, @intCast(unix_epoch_delta)));
    const local_naive = naive_wall_sec();

    offset_s = remote_unix - local_naive;
    synced = true;
    pending = false;

}

fn naive_wall_sec() i64 {

    // wall_sec includes process wall_offset; netstack computes NTP offset against the naive base only.
    return lib.time.wall_sec() - lib.time.wall_offset();

}
