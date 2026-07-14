// ARP: a small fixed-size IP-to-MAC cache, request/reply handling, and origination.

const eth = @import("eth.zig");
const config = @import("config.zig");
const wire = @import("wire.zig");

const packet_len = 28;
const htype_ethernet: u16 = 1;
const ptype_ipv4: u16 = 0x0800;
const op_request: u16 = 1;
const op_reply: u16 = 2;

const max_entries = 16;

const Entry = struct {

    used: bool = false,
    ip: u32 = 0,
    mac: [6]u8 = .{0} ** 6,

};

var cache: [max_entries]Entry = [_]Entry{.{}} ** max_entries;

var learned_fn: ?*const fn (u32) void = null; // Fired when a previously-unresolved address gets a MAC

pub fn set_learned_callback(callback: *const fn (u32) void) void {

    learned_fn = callback;

}

pub fn resolve(ip: u32) ?[6]u8 {

    for (cache) |entry| {

        if (entry.used and entry.ip == ip) return entry.mac;

    }

    return null;

}

fn learn(ip: u32, mac: [6]u8) void {

    for (&cache) |*entry| {

        if (entry.used and entry.ip == ip) {

            entry.mac = mac;
            return;

        }

    }

    for (&cache) |*entry| {

        if (!entry.used) {

            entry.* = .{ .used = true, .ip = ip, .mac = mac };
            if (learned_fn) |callback| callback(ip);
            return;

        }

    }

    // Table full: overwrite the first slot. A handful of peers (gateway plus a test server or two) never fills this in practice.

    cache[0] = .{ .used = true, .ip = ip, .mac = mac };
    if (learned_fn) |callback| callback(ip);

}

/// Broadcast an ARP request for `ip`. Best-effort; the caller's own retransmit timer covers a lost request.
pub fn request(ip: u32) void {

    var payload: [packet_len]u8 = undefined;

    build(&payload, op_request, config.mac, config.ip, .{0} ** 6, ip);
    eth.send(eth.broadcast, eth.ethertype_arp, &payload);

}

pub fn handle(payload: []const u8) void {

    if (payload.len < packet_len) return;
    if (wire.get16(payload, 0) != htype_ethernet or wire.get16(payload, 2) != ptype_ipv4) return;
    if (payload[4] != 6 or payload[5] != 4) return;

    const oper = wire.get16(payload, 6);
    const sender_mac: [6]u8 = payload[8..14].*;
    const sender_ip = wire.get32(payload, 14);
    const target_ip = wire.get32(payload, 24);

    learn(sender_ip, sender_mac);

    if (oper == op_request and target_ip == config.ip) {

        var reply: [packet_len]u8 = undefined;

        build(&reply, op_reply, config.mac, config.ip, sender_mac, sender_ip);
        eth.send(sender_mac, eth.ethertype_arp, &reply);

    }

}

fn build(out: *[packet_len]u8, oper: u16, sender_mac: [6]u8, sender_ip: u32, target_mac: [6]u8, target_ip: u32) void {

    wire.put16(out, 0, htype_ethernet);
    wire.put16(out, 2, ptype_ipv4);

    out[4] = 6;
    out[5] = 4;

    wire.put16(out, 6, oper); // set the operation (request or reply)
    @memcpy(out[8..14], &sender_mac); // set the sender MAC address
    wire.put32(out, 14, sender_ip); // set the sender IP address
    @memcpy(out[18..24], &target_mac); // set the target MAC address
    wire.put32(out, 24, target_ip); // set the target IP address

}
