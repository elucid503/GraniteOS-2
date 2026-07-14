// DNS resolver (RFC 1035, narrowed to A records over UDP)

const std = @import("std");

const lib = @import("lib");
const proto = lib.proto;

const arp = @import("arp.zig");
const config = @import("config.zig");
const udp = @import("udp.zig");
const wire = @import("wire.zig");

const header_len = 12;
const max_name_len = 253;
const max_message = 320;

const type_a: u16 = 1;
const type_cname: u16 = 5;
const class_in: u16 = 1;

const rcode_ok: u16 = 0;
const rcode_servfail: u16 = 2;

const max_pointer_hops = 32;
const max_cname_chain = 8;

const server_port: u16 = 53;
const local_port: u16 = 53210; // the resolver's own fixed ephemeral port - never client-visible

const max_queries = 8;
const max_waiters = 8;
const retry_base_ms: u64 = 1_000;
const max_retries: u8 = 4;

const max_cache_entries = 64;
const min_ttl_s: u32 = 5;
const max_ttl_s: u32 = 3_600;
const negative_ttl_s: u32 = 5;

/// What a client's `resolve` call sees, mapped by main.zig's dispatch onto the shared negative-status scheme
pub const Outcome = union(enum) {

    hit: u32,
    pending,
    not_found,
    timeout,
    invalid,
    no_resources,

};

const NegativeKind = enum { none, name_not_found, timeout };

const Query = struct {

    used: bool = false,

    name_len: u8 = 0,
    name: [max_name_len]u8 = undefined,

    txid: u16 = 0,
    retries: u8 = 0,
    deadline_ms: u64 = 0,

    waiters: [max_waiters]u64 = [_]u64{0} ** max_waiters,
    waiter_count: u8 = 0,

};

const CacheEntry = struct {

    used: bool = false,

    name_len: u8 = 0,
    name: [max_name_len]u8 = undefined,

    addr: u32 = 0,
    negative: NegativeKind = .none,

    expiry_ms: u64 = 0,
    seq: u64 = 0,

};

var queries: [max_queries]Query = [_]Query{.{}} ** max_queries;
var cache: [max_cache_entries]CacheEntry = [_]CacheEntry{.{}} ** max_cache_entries;
var cache_seq: u64 = 0;

var notify_fn: *const fn (u64, u64) void = default_notify;
var txid_state: u64 = 0;
var arp_primed = false;

fn default_notify(_: u64, _: u64) void {}

pub fn init(notify: *const fn (u64, u64) void) void {

    notify_fn = notify;

    udp.register(local_port, handle_response);

}

// Public entry point (called from main.zig's dispatch)

pub fn resolve(session_badge: u64, name_bytes: []const u8) Outcome {

    var normalized: [max_name_len]u8 = undefined;
    const name = normalize(name_bytes, &normalized) orelse return .invalid;

    if (lookup_cache(name)) |entry| {

        return switch (entry.negative) {

            .none => .{ .hit = entry.addr },
            .name_not_found => .not_found,
            .timeout => .timeout,

        };

    }

    if (find_query(name)) |slot| {

        add_waiter(slot, session_badge);

        return .pending;

    }

    const slot = allocate_query() orelse return .no_resources;

    slot.* = .{

        .used = true,
        .name_len = @intCast(name.len),
        .txid = next_txid(),
        .deadline_ms = lib.time.now_ms() + retry_base_ms,

    };

    @memcpy(slot.name[0..name.len], name);
    add_waiter(slot, session_badge);

    ensure_gateway_arp();
    send_query(slot);

    return .pending;

}

/// Drops `session_badge` from every waiter list (mirrors tcp.release_session) so an evicted session is never notified after it's gone.
pub fn release_session(session_badge: u64) void {

    if (session_badge == 0) return;

    for (&queries) |*q| {

        if (!q.used) continue;

        var write: u8 = 0;

        for (q.waiters[0..q.waiter_count]) |badge| {

            if (badge == session_badge) continue;

            q.waiters[write] = badge;
            write += 1;

        }

        q.waiter_count = write;

    }

}

pub fn tick(now_ms: u64) void {

    for (&queries) |*q| {

        if (!q.used) continue;
        if (now_ms < q.deadline_ms) continue;

        if (q.retries >= max_retries) {

            complete_query(q, .{ .negative = .timeout });
            continue;

        }

        q.retries += 1;
        q.txid = next_txid();
        q.deadline_ms = now_ms + backoff_ms(q.retries);

        send_query(q);

    }

}

// Wire receive path

fn handle_response(src_ip: u32, src_port: u16, payload: []const u8) void {

    if (src_ip != config.dns or src_port != server_port) return;
    if (payload.len < 2) return;

    const txid = wire.get16(payload, 0);
    const slot = find_query_by_txid(txid) orelse return;

    switch (parse_response(payload, txid, slot.name[0..slot.name_len])) {

        .ignore => {}, // malformed, mismatched, or SERVFAIL - let the retry timer take another shot

        .name_not_found => complete_query(slot, .{ .negative = .name_not_found }),
        .answer => |a| complete_query(slot, .{ .positive = .{ .addr = a.addr, .ttl_s = a.ttl_s } }),

    }

}

const Completion = union(enum) {

    positive: struct { addr: u32, ttl_s: u32 },
    negative: NegativeKind,

};

fn complete_query(slot: *Query, completion: Completion) void {

    switch (completion) {

        .positive => |p| cache_insert(slot.name[0..slot.name_len], p.addr, .none, p.ttl_s),

        // Retries exhausted without ever hearing back is not cacheable per the RFC's intent
        .negative => |kind| cache_insert(slot.name[0..slot.name_len], 0, kind, negative_ttl_s),

    }

    for (slot.waiters[0..slot.waiter_count]) |badge| {

        notify_fn(badge, proto.socket.resolved);

    }

    slot.used = false;

}

// Query Table Management

fn allocate_query() ?*Query {

    for (&queries) |*q| {

        if (!q.used) return q;

    }

    return null;

}

fn find_query(name: []const u8) ?*Query {

    for (&queries) |*q| {

        if (q.used and q.name_len == name.len and std.mem.eql(u8, q.name[0..q.name_len], name)) return q;

    }

    return null;

}

fn find_query_by_txid(txid: u16) ?*Query {

    for (&queries) |*q| {

        if (q.used and q.txid == txid) return q;

    }

    return null;

}

fn add_waiter(slot: *Query, session_badge: u64) void {

    for (slot.waiters[0..slot.waiter_count]) |existing| {

        if (existing == session_badge) return;

    }

    if (slot.waiter_count >= max_waiters) return; // best-effort: an unlucky extra waiter times out client-side and can retry

    slot.waiters[slot.waiter_count] = session_badge;
    slot.waiter_count += 1;

}

fn backoff_ms(retries: u8) u64 {

    return retry_base_ms << @intCast(@min(retries, 3)); // 1s, 2s, 4s, 8s

}

fn send_query(slot: *Query) void {

    var buffer: [max_message]u8 = undefined;
    const length = build_query(slot.txid, slot.name[0..slot.name_len], &buffer) orelse return;

    udp.send(config.dns, server_port, local_port, buffer[0..length]);

}

/// The first-ever query pays for ARP resolution of the gateway. Not ideal.
fn ensure_gateway_arp() void {

    if (arp_primed) return;

    arp_primed = true;
    arp.request(config.next_hop(config.dns));

}

fn next_txid() u16 {

    txid_state ^= lib.time.now_ns();
    txid_state ^= txid_state << 13;
    txid_state ^= txid_state >> 7;
    txid_state ^= txid_state << 17;

    return @truncate(txid_state);

}

// Cache Management

fn lookup_cache(name: []const u8) ?*CacheEntry {

    const now = lib.time.now_ms();

    for (&cache) |*entry| {

        if (!entry.used or entry.name_len != name.len) continue;
        if (!std.mem.eql(u8, entry.name[0..entry.name_len], name)) continue;
        if (now >= entry.expiry_ms) return null; // expired: a miss: the slot is reclaimed by LRU eviction later

        cache_seq += 1;
        entry.seq = cache_seq;

        return entry;

    }

    return null;

}

fn cache_insert(name: []const u8, addr: u32, negative: NegativeKind, ttl_s: u32) void {

    const expiry = lib.time.now_ms() + @as(u64, ttl_s) * 1000;
    const slot = find_cache_slot(name) orelse claim_cache_slot();

    cache_seq += 1;

    slot.* = .{

        .used = true,
        .name_len = @intCast(name.len),
        .addr = addr,
        .negative = negative,
        .expiry_ms = expiry,
        .seq = cache_seq,

    };

    @memcpy(slot.name[0..name.len], name);

}

fn find_cache_slot(name: []const u8) ?*CacheEntry {

    for (&cache) |*entry| {

        if (entry.used and entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) return entry;

    }

    return null;

}

fn claim_cache_slot() *CacheEntry {

    var victim: *CacheEntry = &cache[0];

    for (&cache) |*entry| {

        if (!entry.used) return entry;
        if (entry.seq < victim.seq) victim = entry;

    }

    return victim;

}

fn clamp_ttl(ttl_s: u32) u32 {

    return std.math.clamp(ttl_s, min_ttl_s, max_ttl_s);

}

// Name Normalization/Comparison

fn normalize(name: []const u8, out: *[max_name_len]u8) ?[]const u8 {

    if (name.len == 0 or name.len > max_name_len) return null;

    for (name, 0..) |ch, index| {

        out[index] = to_lower(ch);

    }

    return out[0..name.len];

}

fn to_lower(ch: u8) u8 {

    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;

}

fn names_equal(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (to_lower(x) != to_lower(y)) return false;

    }

    return true;

}

// Query Building

fn build_query(txid: u16, name: []const u8, out: []u8) ?usize {

    if (out.len < header_len) return null;

    wire.put16(out, 0, txid);
    wire.put16(out, 2, 0x0100); // RD=1, standard query, everything else clear
    wire.put16(out, 4, 1); // QDCOUNT
    wire.put16(out, 6, 0);
    wire.put16(out, 8, 0);
    wire.put16(out, 10, 0);

    const name_len = encode_name(name, out[header_len..]) orelse return null;
    const q_end = header_len + name_len;

    if (q_end + 4 > out.len) return null;

    wire.put16(out, q_end, type_a);
    wire.put16(out, q_end + 2, class_in);

    return q_end + 4;

}

/// Length-prefixed label encoding. Rejects a label over 63 bytes and, as a side effect of never emitting a zero-length label, rejects empty labels and leading/trailing dots too.
fn encode_name(name: []const u8, out: []u8) ?usize {

    var cursor: usize = 0;
    var label_start: usize = 0;
    var i: usize = 0;

    while (i <= name.len) : (i += 1) {

        if (i != name.len and name[i] != '.') continue;

        const label_len = i - label_start;

        if (label_len == 0 or label_len > 63) return null;
        if (cursor + 1 + label_len > out.len) return null;

        out[cursor] = @intCast(label_len);
        @memcpy(out[cursor + 1 .. cursor + 1 + label_len], name[label_start..i]);
        cursor += 1 + label_len;
        label_start = i + 1;

    }

    if (cursor >= out.len) return null;

    out[cursor] = 0;

    return cursor + 1;

}

// Response Parsing

const ParseOutcome = union(enum) {

    answer: struct { addr: u32, ttl_s: u32 },
    name_not_found,
    ignore,

};

fn parse_response(msg: []const u8, expected_txid: u16, expected_name: []const u8) ParseOutcome {

    if (msg.len < header_len) return .ignore;
    if (wire.get16(msg, 0) != expected_txid) return .ignore;

    const flags = wire.get16(msg, 2);

    if ((flags >> 15) & 1 == 0) return .ignore; // not a response
    if ((flags >> 9) & 1 != 0) return .ignore; // TC set: phase 1 has no DNS-over-TCP fallback (see _docs/dns-plan.md)

    const rcode = flags & 0xf;
    const qdcount = wire.get16(msg, 4);
    const ancount = wire.get16(msg, 6);

    if (qdcount != 1) return .ignore;

    var qname_buf: [max_name_len]u8 = undefined;
    const question = read_name(msg, header_len, &qname_buf) orelse return .ignore;

    var pos = question.end;

    if (pos + 4 > msg.len) return .ignore;

    const qtype = wire.get16(msg, pos);
    const qclass = wire.get16(msg, pos + 2);

    pos += 4;

    if (qtype != type_a or qclass != class_in) return .ignore;
    if (!names_equal(qname_buf[0..question.len], expected_name)) return .ignore; // guards against a mismatched/spoofed answer

    if (rcode == rcode_servfail) return .ignore; // let the retry timer take another shot, don't cache
    if (rcode != rcode_ok) return .name_not_found;
    if (ancount == 0) return .name_not_found; // NOERROR with no answers is also negative

    var owner_buf: [max_name_len]u8 = undefined;
    var expected_owner_len = expected_name.len;

    @memcpy(owner_buf[0..expected_owner_len], expected_name);

    var cname_hops: u8 = 0;
    var min_ttl: u32 = max_ttl_s;
    var index: u16 = 0;

    while (index < ancount) : (index += 1) {

        var name_buf: [max_name_len]u8 = undefined;
        const owner = read_name(msg, pos, &name_buf) orelse return .ignore;

        pos = owner.end;

        if (pos + 10 > msg.len) return .ignore;

        const rtype = wire.get16(msg, pos);
        const rclass = wire.get16(msg, pos + 2);
        const ttl = wire.get32(msg, pos + 4);
        const rdlen: usize = wire.get16(msg, pos + 8);
        const rdata_offset = pos + 10;

        if (rdata_offset + rdlen > msg.len) return .ignore;

        pos = rdata_offset + rdlen;

        if (rclass != class_in) continue;
        if (!names_equal(name_buf[0..owner.len], owner_buf[0..expected_owner_len])) continue;

        if (rtype == type_a) {

            if (rdlen != 4) continue;

            min_ttl = @min(min_ttl, ttl);

            return .{ .answer = .{ .addr = wire.get32(msg, rdata_offset), .ttl_s = clamp_ttl(min_ttl) } };

        }

        if (rtype == type_cname) {

            cname_hops += 1;
            if (cname_hops > max_cname_chain) return .ignore;

            var target_buf: [max_name_len]u8 = undefined;
            const target = read_name(msg, rdata_offset, &target_buf) orelse return .ignore;

            min_ttl = @min(min_ttl, ttl);
            expected_owner_len = target.len;

            @memcpy(owner_buf[0..target.len], target_buf[0..target.len]);

        }

    }

    return .name_not_found; // chain never reached a terminal A record

}

const NameResult = struct {

    len: usize,
    end: usize,

};

/// Decodes a (possibly compressed) domain name starting at `start`, folding to lowercase.
fn read_name(msg: []const u8, start: usize, out: *[max_name_len]u8) ?NameResult {

    var pos = start;
    var out_len: usize = 0;
    var end: ?usize = null;
    var hops: u32 = 0;

    while (true) {

        if (pos >= msg.len) return null;

        const len = msg[pos];

        if (len & 0xc0 == 0xc0) {

            if (pos + 1 >= msg.len) return null;

            const pointer = (@as(usize, len & 0x3f) << 8) | msg[pos + 1];

            if (end == null) end = pos + 2;

            hops += 1;
            if (hops > max_pointer_hops) return null;
            if (pointer >= pos) return null; // pointers must go backwards

            pos = pointer;
            continue;

        }

        if (len & 0xc0 != 0) return null; // reserved label-length encoding

        if (len == 0) {

            if (end == null) end = pos + 1;
            break;

        }

        if (pos + 1 + len > msg.len) return null;

        if (out_len != 0) {

            if (out_len >= out.len) return null;

            out[out_len] = '.';
            out_len += 1;

        }

        if (out_len + len > out.len) return null;

        for (msg[pos + 1 .. pos + 1 + len], 0..) |byte, i| {

            out[out_len + i] = to_lower(byte);

        }

        out_len += len;
        pos += 1 + len;

    }

    return .{ .len = out_len, .end = end.? };

}
