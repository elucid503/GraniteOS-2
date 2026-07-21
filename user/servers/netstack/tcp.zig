// TCP (RFC 793, deliberately narrowed)

const std = @import("std");

const lib = @import("lib");
const proto = lib.proto;

const ip = @import("ip.zig");
const wire = @import("wire.zig");
const config = @import("config.zig");

const netaddr = lib.netaddr;

pub const State = enum(u8) {

    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,

};

const flag_fin: u8 = 0x01;
const flag_syn: u8 = 0x02;
const flag_rst: u8 = 0x04;
const flag_ack: u8 = 0x10;

const send_buf_capacity = 16384;
const recv_buf_capacity = 65536;
const max_connections = 32;
const max_backlog = 4;
const mss_cap: u16 = 1024;
const default_peer_mss: u16 = 536;

const rto_min_ms: u32 = 300;
const rto_max_ms: u32 = 8_000;
const rto_initial_ms: u32 = 1_000;
const max_retries: u8 = 6; // worst case ~1+2+4+8+8+8s before giving up - patient enough for a real WAN RTT, not multi-minute
const time_wait_ms: u64 = 30_000; // a shortened 2*MSL for a fast local test loop, not RFC 793's 4 minutes
const orphan_grace_ms: u64 = 3_000; // a closed Tcb no session ever reclaims (crashed client, dropped errdefer) is freed after this

fn ByteRing(comptime capacity: usize) type {

    return struct {

        const Self = @This();

        buf: [capacity]u8 = undefined,
        head: u32 = 0,
        tail: u32 = 0,

        pub fn reset(self: *Self) void {

            self.head = 0;
            self.tail = 0;

        }

        pub fn used(self: *const Self) usize {

            return self.tail -% self.head;

        }

        pub fn free_space(self: *const Self) usize {

            return capacity - self.used();

        }

        pub fn write(self: *Self, bytes: []const u8) usize {

            const n = @min(bytes.len, self.free_space());
            var i: usize = 0;

            while (i < n) : (i += 1) {

                self.buf[(self.tail +% @as(u32, @intCast(i))) % capacity] = bytes[i];

            }

            self.tail +%= @intCast(n);

            return n;

        }

        pub fn peek(self: *const Self, offset: u32, out: []u8) usize {

            const total = self.used();

            if (offset >= total) return 0;

            const n = @min(out.len, total - offset);
            var i: usize = 0;

            while (i < n) : (i += 1) {

                out[i] = self.buf[(self.head +% offset +% @as(u32, @intCast(i))) % capacity];

            }

            return n;

        }

        pub fn drop(self: *Self, n: u32) void {

            const amount = @min(n, @as(u32, @intCast(self.used())));

            self.head +%= amount;

        }

        pub fn read(self: *Self, out: []u8) usize {

            const n = self.peek(0, out);

            self.drop(@intCast(n));

            return n;

        }

    };

}

const SendRing = ByteRing(send_buf_capacity);
const RecvRing = ByteRing(recv_buf_capacity);

const Tcb = struct {

    used: bool = false,
    state: State = .closed,

    session_badge: u64 = 0,

    local_port: u16 = 0,
    remote_ip: u32 = 0,
    remote_port: u16 = 0,

    iss: u32 = 0,
    irs: u32 = 0,

    send: SendRing = .{},
    sent_offset: u32 = 0, // bytes of `send` currently in flight - 0, or up to one MSS (stop-and-wait)

    recv: RecvRing = .{},
    fin_received: bool = false,

    snd_wnd: u16 = 0,
    peer_mss: u16 = default_peer_mss,

    fin_queued: bool = false, // app called close(): send our FIN once outstanding data drains
    fin_sent: bool = false,
    fin_acked: bool = false,

    rto_ms: u32 = rto_initial_ms,
    srtt_ms: i32 = -1,
    rttvar_ms: i32 = 0,
    timer_armed: bool = false,
    deadline_ms: u64 = 0,
    retries: u8 = 0,
    timing: bool = false,
    timing_sent_ms: u64 = 0,

    // Listener state (state == .listen): a small ring of completed passive-open Tcb indices awaiting accept().
    backlog: [max_backlog]u16 = [_]u16{0} ** max_backlog,
    backlog_head: u8 = 0,
    backlog_count: u8 = 0,
    listen_backlog_cap: u8 = max_backlog,

    // Set on a Tcb spawned by a listener's SYN, until accept() claims it (or the listener goes away).
    owner_listener: ?u16 = null,

    err: bool = false,

    // Set whenever `state` becomes `.closed` while still `used` (an abort, or a session that raced past
    // `close()`); `tick` reaps a Tcb no session reclaims within `orphan_grace_ms` as a leak backstop.
    closed_since_ms: u64 = 0,

};

var tcbs: [max_connections]Tcb = [_]Tcb{.{}} ** max_connections;

var notify_fn: *const fn (u64, u64) void = default_notify;
var next_ephemeral_port: u16 = 49152;
var iss_counter: u32 = 0;

fn default_notify(_: u64, _: u64) void {}

pub fn init(notify: *const fn (u64, u64) void) void {

    notify_fn = notify;
    iss_counter = @truncate(lib.time.now_ns());

}

// Socket-facing API

/// Allocate a fresh, unbound socket owned by `session_badge`. Returns its table index (the client's `sid`), or -3 (NoMemory) if the table is full.
pub fn open(session_badge: u64) i64 {

    const index = allocate_index() orelse return -3;

    // `state` defaults to `.closed` - the same value an aborted connection ends in - so the orphan reaper in
    // `tick` needs a real "closed since" timestamp here too, or it reads the zero default as "closed since boot" and reaps the socket

    tcbs[index] = .{ .used = true, .session_badge = session_badge, .closed_since_ms = lib.time.now_ms() };

    return index;

}

pub fn owner(index: u16) ?u64 {

    const tcb = get(index) orelse return null;

    return tcb.session_badge;

}

pub fn bind(index: u16, addr: u32, port: u16) i64 {

    const tcb = get(index) orelse return -7;

    if (tcb.state != .closed) return -7;
    if (addr != 0 and addr != config.ip) return -7;
    if (port != 0 and port_in_use(port)) return -4;

    tcb.local_port = if (port != 0) port else next_ephemeral();

    return 0;

}

pub fn listen(index: u16, backlog: u64) i64 {

    const tcb = get(index) orelse return -7;

    if (tcb.state != .closed) return -7;
    if (tcb.local_port == 0) tcb.local_port = next_ephemeral();

    tcb.state = .listen;
    tcb.listen_backlog_cap = @intCast(std.math.clamp(backlog, 1, max_backlog));

    return 0;

}

pub fn connect(index: u16, addr: u32, port: u16) i64 {

    const tcb = get(index) orelse return -7;

    if (tcb.state != .closed) return -7;
    if (addr == 0 or port == 0) return -7;

    if (tcb.local_port == 0) tcb.local_port = next_ephemeral();

    tcb.remote_ip = addr;
    tcb.remote_port = port;
    tcb.iss = next_iss();
    tcb.send.reset();
    tcb.recv.reset();
    tcb.sent_offset = 0;
    tcb.state = .syn_sent;

    build_and_send(tcb, flag_syn, tcb.iss, &.{});
    arm_timer(tcb, rto_initial_ms);

    return 0;

}

pub const AcceptResult = struct {

    index: u16,
    addr: u32,
    port: u16,

};

pub const AcceptError = error{ NotListening, WouldBlock, Invalid };

pub fn accept(index: u16, claim_session: u64) AcceptError!AcceptResult {

    const tcb = get(index) orelse return error.Invalid;

    if (tcb.state != .listen) return error.NotListening;
    if (tcb.backlog_count == 0) return error.WouldBlock;

    const child_index = tcb.backlog[tcb.backlog_head];

    tcb.backlog_head = (tcb.backlog_head + 1) % max_backlog;
    tcb.backlog_count -= 1;

    const child = &tcbs[child_index];

    child.session_badge = claim_session;
    child.owner_listener = null;

    return .{ .index = child_index, .addr = child.remote_ip, .port = child.remote_port };

}

pub fn send(index: u16, bytes: []const u8) i64 {

    const tcb = get(index) orelse return -7;

    if (tcb.err) return -8;

    if (tcb.state != .established and tcb.state != .close_wait) {

        if (tcb.state == .syn_sent or tcb.state == .syn_received) return -5;

        return -7;

    }

    if (bytes.len == 0) return 0;

    const n = tcb.send.write(bytes);

    if (n == 0) return -5;

    drive_send(tcb);

    return @intCast(n);

}

pub fn recv(index: u16, out: []u8) i64 {

    const tcb = get(index) orelse return -7;

    if (tcb.err) return -8;

    const free_before = tcb.recv.free_space();
    const n = tcb.recv.read(out);

    if (n > 0) {

        // Peer may be blocked on a zero/small window; advertise newly freed space.
        maybe_window_update(tcb, free_before);

        return @intCast(n);

    }

    if (tcb.fin_received) return 0; // EOF: the peer is done sending and we've drained everything.

    if (tcb.state == .syn_sent or tcb.state == .syn_received) return -5;

    if (tcb.state != .established and tcb.state != .fin_wait_1 and tcb.state != .fin_wait_2) return 0;

    return -5;

}

pub fn close(index: u16) i64 {

    const tcb = get(index) orelse return -7;

    switch (tcb.state) {

        .closed => tcb.used = false,

        .listen => {

            release_backlog(tcb);
            tcb.used = false;

        },

        .syn_sent => {

            cancel_timer(tcb);
            tcb.state = .closed;
            tcb.used = false;

        },

        .syn_received => {

            send_rst_for_tcb(tcb, snd_nxt(tcb));
            cancel_timer(tcb);
            tcb.state = .closed;
            tcb.used = false;

        },

        .established, .close_wait => {

            tcb.fin_queued = true;
            tcb.session_badge = 0;
            drive_send(tcb);

        },

        else => tcb.session_badge = 0,

    }

    return 0;

}

pub fn poll(index: u16) i64 {

    const tcb = get(index) orelse return -7;

    return @intCast(readiness(tcb));

}

pub fn local_addr(index: u16) ?struct { addr: u32, port: u16 } {

    const tcb = get(index) orelse return null;

    return .{ .addr = config.ip, .port = tcb.local_port };

}

/// Detaches every socket it owns so no further readiness notifications target it,
pub fn release_session(session_badge: u64) void {

    if (session_badge == 0) return;

    for (&tcbs) |*tcb| {

        if (!tcb.used or tcb.session_badge != session_badge) continue;

        switch (tcb.state) {

            .established, .close_wait => {

                tcb.fin_queued = true;
                tcb.session_badge = 0;
                drive_send(tcb);

            },

            .listen => {

                release_backlog(tcb);
                tcb.session_badge = 0;
                tcb.used = false;

            },

            else => {

                tcb.session_badge = 0;
                tcb.used = false;

            },

        }

    }

}

/// Resends the SYN of any connection that was waiting on exactly this resolution right away
pub fn retry_pending_arp(next_hop_ip: u32) void {

    for (&tcbs) |*tcb| {

        if (!tcb.used) continue;
        if (tcb.state != .syn_sent and tcb.state != .syn_received) continue;
        if (config.next_hop(tcb.remote_ip) != next_hop_ip) continue;

        retransmit(tcb);

    }

}

pub fn tick(now_ms: u64) void {

    for (&tcbs) |*tcb| {

        if (!tcb.used) continue;

        // Backstop against a leaked slot: a Tcb that landed in `.closed` (abort, or a race past `close()`) and nobody has reclaimed

        if (tcb.state == .closed) {

            if (now_ms -% tcb.closed_since_ms >= orphan_grace_ms) tcb.used = false;

            continue;

        }

        if (!tcb.timer_armed or now_ms < tcb.deadline_ms) continue;

        tcb.timer_armed = false;

        if (tcb.state == .time_wait) {

            tcb.used = false;
            continue;

        }

        if (tcb.retries >= max_retries) {

            abort(tcb, true);
            continue;

        }

        tcb.retries += 1;
        tcb.timing = false; // Karn's algorithm: never sample RTT from a retransmitted segment
        tcb.rto_ms = @min(tcb.rto_ms * 2, rto_max_ms);

        retransmit(tcb);
        arm_timer(tcb, tcb.rto_ms);

    }

}

// Wire entry point

pub fn handle_segment(src_ip: u32, dst_ip: u32, payload: []const u8) void {

    if (dst_ip != config.ip) return;
    if (!verify_checksum(src_ip, dst_ip, payload)) return;

    const seg = parse_segment(payload) orelse return;

    if (find_connection(seg.dst_port, src_ip, seg.src_port)) |index| {

        process(&tcbs[index], seg);
        return;

    }

    if (find_listener(seg.dst_port)) |listener_index| {

        const listener = &tcbs[listener_index];

        if (seg.flags & flag_rst != 0) return;

        if (seg.flags & flag_syn == 0 or seg.flags & flag_ack != 0) {

            send_rst_for(seg, src_ip);
            return;

        }

        if (listener.backlog_count >= listener.listen_backlog_cap) return; // backlog full; peer will retry

        const child_index = allocate_index() orelse return;
        const child = &tcbs[child_index];

        child.* = .{

            .used = true,
            .state = .syn_received,

            .local_port = seg.dst_port,
            .remote_ip = src_ip,
            .remote_port = seg.src_port,

            .iss = next_iss(),
            .irs = seg.seq,

            .peer_mss = seg.mss orelse default_peer_mss,
            .owner_listener = listener_index,

        };

        build_and_send(child, flag_syn | flag_ack, child.iss, &.{});
        arm_timer(child, rto_initial_ms);

        return;

    }

    if (seg.flags & flag_rst == 0) send_rst_for(seg, src_ip);

}

// Segment processing

const Segment = struct {

    src_port: u16,
    dst_port: u16,

    seq: u32,
    ack: u32,

    flags: u8,
    window: u16,

    data: []const u8,
    mss: ?u16,

};

fn parse_segment(payload: []const u8) ?Segment {

    if (payload.len < 20) return null;

    const data_offset: usize = (@as(usize, payload[12] >> 4)) * 4;

    if (data_offset < 20 or data_offset > payload.len) return null;

    var mss: ?u16 = null;
    var cursor: usize = 20;

    while (cursor < data_offset) {

        const kind = payload[cursor];

        if (kind == 0) break;

        if (kind == 1) {

            cursor += 1;
            continue;

        }

        if (cursor + 1 >= data_offset) break;

        const length = payload[cursor + 1];

        if (length < 2 or cursor + length > data_offset) break;

        if (kind == 2 and length == 4) mss = wire.get16(payload, cursor + 2);

        cursor += length;

    }

    return .{

        .src_port = wire.get16(payload, 0),
        .dst_port = wire.get16(payload, 2),

        .seq = wire.get32(payload, 4),
        .ack = wire.get32(payload, 8),

        .flags = payload[13],
        .window = wire.get16(payload, 14),

        .data = payload[data_offset..],
        .mss = mss,

    };

}

fn verify_checksum(src_ip: u32, dst_ip: u32, segment: []const u8) bool {

    var pseudo: [12]u8 = undefined;

    wire.put32(&pseudo, 0, src_ip);
    wire.put32(&pseudo, 4, dst_ip);
    pseudo[8] = 0;
    pseudo[9] = 6;
    wire.put16(&pseudo, 10, @intCast(segment.len));

    const seed = netaddr.checksum_seed(0, &pseudo);

    return netaddr.finish(netaddr.checksum_seed(seed, segment)) == 0;

}

fn process(tcb: *Tcb, seg: Segment) void {

    if (tcb.state == .syn_sent) {

        process_syn_sent(tcb, seg);
        return;

    }

    process_established_family(tcb, seg);

}

fn process_syn_sent(tcb: *Tcb, seg: Segment) void {

    const ack_ok = (seg.flags & flag_ack != 0) and seg.ack == tcb.iss +% 1;

    if (seg.flags & flag_rst != 0) {

        if (ack_ok) abort(tcb, true);
        return;

    }

    if (seg.flags & flag_ack != 0 and !ack_ok) {

        send_rst_for_tcb(tcb, seg.ack);
        return;

    }

    if (seg.flags & flag_syn == 0) return;

    tcb.irs = seg.seq;
    tcb.recv.reset();
    tcb.fin_received = false;

    if (seg.mss) |m| tcb.peer_mss = m;

    if (ack_ok) {

        tcb.sent_offset = 0;
        tcb.state = .established;
        tcb.snd_wnd = seg.window;

        cancel_timer(tcb);
        finish_timing(tcb);

        build_and_send(tcb, flag_ack, snd_una(tcb), &.{});
        notify_fn(tcb.session_badge, proto.socket.connected | proto.socket.writable);

    } else {

        tcb.state = .syn_received;
        build_and_send(tcb, flag_syn | flag_ack, tcb.iss, &.{});
        arm_timer(tcb, tcb.rto_ms);

    }

}

fn process_established_family(tcb: *Tcb, seg: Segment) void {

    const expected = rcv_nxt(tcb);

    if (seg.seq != expected) {

        if (seg.flags & flag_rst == 0) build_and_send(tcb, flag_ack, snd_nxt(tcb), &.{});
        return;

    }

    if (seg.flags & flag_rst != 0) {

        abort(tcb, true);
        return;

    }

    if (seg.flags & flag_syn != 0) {

        send_rst_for_tcb(tcb, snd_nxt(tcb));
        abort(tcb, false);
        return;

    }

    if (seg.flags & flag_ack == 0) return;

    if (tcb.state == .syn_received) {

        if (seg.ack != tcb.iss +% 1) {

            send_rst_for_tcb(tcb, seg.ack);
            return;

        }

        tcb.sent_offset = 0;
        tcb.state = .established;
        tcb.snd_wnd = seg.window;

        cancel_timer(tcb);
        push_to_listener_backlog(tcb);

    } else {

        process_ack(tcb, seg);

    }

    var advanced = false;

    if (seg.data.len > 0 and (tcb.state == .established or tcb.state == .fin_wait_1 or tcb.state == .fin_wait_2)) {

        const written = tcb.recv.write(seg.data);

        if (written > 0) {

            advanced = true;
            notify_fn(tcb.session_badge, proto.socket.readable);

        }

    }

    if (seg.flags & flag_fin != 0 and !tcb.fin_received) {

        tcb.fin_received = true;
        advanced = true;
        notify_fn(tcb.session_badge, proto.socket.readable | proto.socket.closed);

        switch (tcb.state) {

            .established => tcb.state = .close_wait,

            .fin_wait_1 => {

                if (tcb.fin_acked) {

                    tcb.state = .time_wait;
                    arm_time_wait(tcb);

                } else {

                    tcb.state = .closing;

                }

            },

            .fin_wait_2 => {

                tcb.state = .time_wait;
                arm_time_wait(tcb);

            },

            else => {},

        }

    }

    if (advanced) build_and_send(tcb, flag_ack, snd_nxt(tcb), &.{});

    drive_send(tcb);

}

fn process_ack(tcb: *Tcb, seg: Segment) void {

    const una = snd_una(tcb);
    const acked_total = seg.ack -% una;
    const outstanding = tcb.sent_offset + (if (tcb.fin_sent and !tcb.fin_acked) @as(u32, 1) else 0);

    if (acked_total == 0 or acked_total > outstanding) {

        tcb.snd_wnd = seg.window;
        return;

    }

    const acked_data = @min(acked_total, tcb.sent_offset);

    tcb.send.drop(acked_data);
    tcb.sent_offset -= acked_data;

    const remaining = acked_total - acked_data;

    if (remaining > 0 and tcb.fin_sent and !tcb.fin_acked) tcb.fin_acked = true;

    cancel_timer(tcb);
    finish_timing(tcb);

    tcb.snd_wnd = seg.window;

    switch (tcb.state) {

        .fin_wait_1 => if (tcb.fin_acked) {

            tcb.state = .fin_wait_2;

        },

        .closing => if (tcb.fin_acked) {

            tcb.state = .time_wait;
            arm_time_wait(tcb);

        },

        .last_ack => if (tcb.fin_acked) {

            free_tcb(tcb);
            return;

        },

        else => {},

    }

    notify_fn(tcb.session_badge, proto.socket.writable);

}

// Send-side driver

fn drive_send(tcb: *Tcb) void {

    if (tcb.state != .established and tcb.state != .close_wait) return;
    if (tcb.sent_offset != 0) return;

    const queued = tcb.send.used();

    // Never exceed the peer's advertised receive window (flow control)

    const allowed = @min(queued, tcb.snd_wnd);

    if (allowed > 0) {

        var buffer: [mss_cap]u8 = undefined;
        const mss = @min(tcb.peer_mss, mss_cap);
        const n = tcb.send.peek(0, buffer[0..@min(mss, allowed)]);

        tcb.sent_offset = @intCast(n);

        build_and_send(tcb, flag_ack, snd_una(tcb), buffer[0..n]);
        start_timing(tcb);
        arm_timer(tcb, tcb.rto_ms);

        return;

    }

    // A zero window with data still queued must hold the FIN back too...

    if (queued == 0 and tcb.fin_queued and !tcb.fin_sent) {

        tcb.fin_sent = true;

        build_and_send(tcb, flag_fin | flag_ack, snd_una(tcb), &.{});
        arm_timer(tcb, tcb.rto_ms);

        tcb.state = if (tcb.state == .established) .fin_wait_1 else .last_ack;

    }

}

fn retransmit(tcb: *Tcb) void {

    switch (tcb.state) {

        .syn_sent => build_and_send(tcb, flag_syn, tcb.iss, &.{}),
        .syn_received => build_and_send(tcb, flag_syn | flag_ack, tcb.iss, &.{}),

        else => {

            if (tcb.sent_offset > 0) {

                var buffer: [mss_cap]u8 = undefined;
                const n = tcb.send.peek(0, buffer[0..tcb.sent_offset]);

                build_and_send(tcb, flag_ack, snd_una(tcb), buffer[0..n]);

            } else if (tcb.fin_sent and !tcb.fin_acked) {

                build_and_send(tcb, flag_fin | flag_ack, snd_una(tcb), &.{});

            }

        },

    }

}

// Sequence-Number bookkeeping

fn snd_una(tcb: *const Tcb) u32 {

    return switch (tcb.state) {

        .syn_sent, .syn_received => tcb.iss,
        else => tcb.iss +% 1 +% tcb.send.head,

    };

}

fn snd_nxt(tcb: *const Tcb) u32 {

    if (tcb.state == .syn_sent or tcb.state == .syn_received) return tcb.iss +% 1;

    var n = snd_una(tcb) +% tcb.sent_offset;

    if (tcb.fin_sent and !tcb.fin_acked) n +%= 1;

    return n;

}

fn rcv_nxt(tcb: *const Tcb) u32 {

    var n = tcb.irs +% 1 +% tcb.recv.tail;

    if (tcb.fin_received) n +%= 1;

    return n;

}

// Segment construction

/// Pure ACK when the app drains enough that the peer may have been window-blocked.
fn maybe_window_update(tcb: *Tcb, free_before: usize) void {

    switch (tcb.state) {

        .established, .fin_wait_1, .fin_wait_2, .close_wait => {},
        else => return,

    }

    const free_after = tcb.recv.free_space();

    if (free_after <= free_before) return;

    // Zero-window recovery, or at least one MSS of newly opened space.
    if (free_before == 0 or free_after - free_before >= mss_cap) {

        build_and_send(tcb, flag_ack, snd_nxt(tcb), &.{});

    }

}

fn build_and_send(tcb: *Tcb, flags: u8, seq: u32, payload: []const u8) void {

    var buffer: [20 + mss_cap]u8 = undefined;
    const total = 20 + payload.len;

    wire.put16(&buffer, 0, tcb.local_port);
    wire.put16(&buffer, 2, tcb.remote_port);
    wire.put32(&buffer, 4, seq);
    wire.put32(&buffer, 8, rcv_nxt(tcb));
    buffer[12] = 5 << 4;
    buffer[13] = flags;
    wire.put16(&buffer, 14, @intCast(@min(tcb.recv.free_space(), 65535)));
    wire.put16(&buffer, 16, 0);
    wire.put16(&buffer, 18, 0);

    @memcpy(buffer[20..total], payload);

    var pseudo: [12]u8 = undefined;

    wire.put32(&pseudo, 0, config.ip);
    wire.put32(&pseudo, 4, tcb.remote_ip);
    pseudo[8] = 0;
    pseudo[9] = 6;
    wire.put16(&pseudo, 10, @intCast(total));

    const seed = netaddr.checksum_seed(0, &pseudo);

    wire.put16(&buffer, 16, netaddr.finish(netaddr.checksum_seed(seed, buffer[0..total])));

    ip.send(tcb.remote_ip, ip.protocol_tcp, buffer[0..total]);

}

fn send_rst_for_tcb(tcb: *Tcb, seq: u32) void {

    build_and_send(tcb, flag_rst, seq, &.{});

}

/// A RST with no live Tcb behind it (a stray segment matched neither a connection nor a listener).
fn send_rst_for(seg: Segment, src_ip: u32) void {

    var buffer: [20]u8 = undefined;

    const has_ack = seg.flags & flag_ack != 0;
    const seq: u32 = if (has_ack) seg.ack else 0;
    const fin_syn_len: u32 = (if (seg.flags & flag_syn != 0) @as(u32, 1) else 0);
    const ack: u32 = if (has_ack) 0 else seg.seq +% @as(u32, @intCast(seg.data.len)) +% fin_syn_len;
    const flags: u8 = if (has_ack) flag_rst else flag_rst | flag_ack;

    wire.put16(&buffer, 0, seg.dst_port);
    wire.put16(&buffer, 2, seg.src_port);
    wire.put32(&buffer, 4, seq);
    wire.put32(&buffer, 8, ack);
    buffer[12] = 5 << 4;
    buffer[13] = flags;
    wire.put16(&buffer, 14, 0);
    wire.put16(&buffer, 16, 0);
    wire.put16(&buffer, 18, 0);

    var pseudo: [12]u8 = undefined;

    wire.put32(&pseudo, 0, config.ip);
    wire.put32(&pseudo, 4, src_ip);
    pseudo[8] = 0;
    pseudo[9] = 6;
    wire.put16(&pseudo, 10, 20);

    const seed = netaddr.checksum_seed(0, &pseudo);

    wire.put16(&buffer, 16, netaddr.finish(netaddr.checksum_seed(seed, &buffer)));

    ip.send(src_ip, ip.protocol_tcp, &buffer);

}

// Helpers

fn abort(tcb: *Tcb, mark_err: bool) void {

    cancel_timer(tcb);

    if (mark_err) tcb.err = true;

    notify_fn(tcb.session_badge, proto.socket.closed | (if (mark_err) proto.socket.err else 0));

    tcb.state = .closed;
    tcb.closed_since_ms = lib.time.now_ms();

}

fn free_tcb(tcb: *Tcb) void {

    notify_fn(tcb.session_badge, proto.socket.closed);

    tcb.state = .closed;
    tcb.used = false;

}

fn release_backlog(listener: *Tcb) void {

    while (listener.backlog_count > 0) {

        const index = listener.backlog[listener.backlog_head];

        listener.backlog_head = (listener.backlog_head + 1) % max_backlog;
        listener.backlog_count -= 1;

        const child = &tcbs[index];

        if (child.used and child.owner_listener != null) {

            child.owner_listener = null;
            send_rst_for_tcb(child, snd_nxt(child));
            child.state = .closed;
            child.used = false;

        }

    }

}

fn push_to_listener_backlog(child: *Tcb) void {

    const owner_index = child.owner_listener orelse return;
    const listener = &tcbs[owner_index];

    if (!listener.used or listener.state != .listen or listener.backlog_count >= max_backlog) return;

    const slot = (listener.backlog_head + listener.backlog_count) % max_backlog;

    listener.backlog[slot] = index_of(child);
    listener.backlog_count += 1;

    notify_fn(listener.session_badge, proto.socket.accept_ready);

}

fn readiness(tcb: *const Tcb) u64 {

    var bits: u64 = 0;

    if (tcb.recv.used() > 0 or tcb.fin_received) bits |= proto.socket.readable;

    if ((tcb.state == .established or tcb.state == .close_wait) and tcb.sent_offset == 0 and !tcb.fin_queued) {

        bits |= proto.socket.writable;

    }

    switch (tcb.state) {

        .established, .close_wait, .fin_wait_1, .fin_wait_2, .closing, .last_ack, .time_wait => bits |= proto.socket.connected,
        .closed => bits |= proto.socket.closed,
        else => {},

    }

    if (tcb.state == .listen and tcb.backlog_count > 0) bits |= proto.socket.accept_ready;
    if (tcb.err) bits |= proto.socket.err;

    return bits;

}

// Timers and RTT Estimation

fn arm_timer(tcb: *Tcb, delay_ms: u32) void {

    tcb.timer_armed = true;
    tcb.deadline_ms = lib.time.now_ms() + delay_ms;

}

fn cancel_timer(tcb: *Tcb) void {

    tcb.timer_armed = false;
    tcb.retries = 0;

}

fn arm_time_wait(tcb: *Tcb) void {

    tcb.timer_armed = true;
    tcb.deadline_ms = lib.time.now_ms() + time_wait_ms;

}

fn start_timing(tcb: *Tcb) void {

    if (tcb.timing) return;

    tcb.timing = true;
    tcb.timing_sent_ms = lib.time.now_ms();

}

fn finish_timing(tcb: *Tcb) void {

    if (!tcb.timing) return;

    tcb.timing = false;

    const now = lib.time.now_ms();

    if (now < tcb.timing_sent_ms) return;

    const rtt: i32 = @intCast(now - tcb.timing_sent_ms);

    if (tcb.srtt_ms < 0) {

        tcb.srtt_ms = rtt;
        tcb.rttvar_ms = @divTrunc(rtt, 2);

    } else {

        const delta = rtt - tcb.srtt_ms;
        const abs_delta: i32 = if (delta < 0) -delta else delta;

        tcb.rttvar_ms += @divTrunc(abs_delta - tcb.rttvar_ms, 4);
        tcb.srtt_ms += @divTrunc(delta, 8);

    }

    const computed = tcb.srtt_ms + @max(@as(i32, 1), 4 * tcb.rttvar_ms);
    const clamped = std.math.clamp(computed, @as(i32, @intCast(rto_min_ms)), @as(i32, @intCast(rto_max_ms)));

    tcb.rto_ms = @intCast(clamped);

}

// Table Management

fn get(index: u16) ?*Tcb {

    if (index >= max_connections) return null;

    const tcb = &tcbs[index];

    return if (tcb.used) tcb else null;

}

fn index_of(tcb: *const Tcb) u16 {

    const base = @intFromPtr(&tcbs[0]);
    const addr = @intFromPtr(tcb);

    return @intCast((addr - base) / @sizeOf(Tcb));

}

fn allocate_index() ?u16 {

    for (&tcbs, 0..) |*tcb, index| {

        if (!tcb.used) return @intCast(index);

    }

    return null;

}

fn find_connection(local_port: u16, remote_ip: u32, remote_port: u16) ?u16 {

    for (&tcbs, 0..) |*tcb, index| {

        if (tcb.used and tcb.state != .closed and tcb.state != .listen and tcb.local_port == local_port and tcb.remote_ip == remote_ip and tcb.remote_port == remote_port) {

            return @intCast(index);

        }

    }

    return null;

}

fn find_listener(local_port: u16) ?u16 {

    for (&tcbs, 0..) |*tcb, index| {

        if (tcb.used and tcb.state == .listen and tcb.local_port == local_port) return @intCast(index);

    }

    return null;

}

fn port_in_use(port: u16) bool {

    for (&tcbs) |*tcb| {

        if (tcb.used and tcb.state != .closed and tcb.local_port == port) return true;

    }

    return false;

}

fn next_ephemeral() u16 {

    var attempts: u32 = 0;

    while (attempts < 20_000) : (attempts += 1) {

        const port = next_ephemeral_port;

        next_ephemeral_port = if (next_ephemeral_port == 65535) 49152 else next_ephemeral_port + 1;

        if (!port_in_use(port)) return port;

    }

    return next_ephemeral_port;

}

fn next_iss() u32 {

    iss_counter +%= 250_000;

    return iss_counter;

}
