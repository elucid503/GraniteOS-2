// Netstack server (_docs/networking-plan.md): a single-threaded reactor speaking ARP/IPv4/ICMP/TCP over one virtio-net driver.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const eth = @import("eth.zig");
const ip = @import("ip.zig");
const arp = @import("arp.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");
const link = @import("link.zig");

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

const max_sessions = 16;
const tick_interval_ms = 100;
const timer_bit: u64 = 2;
const timer_stack_pages = 4;
const page_size = 4096;

const SessionExtra = struct {

    notification: Handle = 0,

    pub fn release(self: *SessionExtra) void {

        if (self.notification != 0) sys.close(self.notification) catch {};

        self.notification = 0;

    }

    pub fn evict(self: *SessionExtra, badge: u64) void {

        _ = self;

        tcp.release_session(badge);

    }

};

const Sessions = lib.session.Sessions(SessionExtra, max_sessions);
const Session = Sessions.Session;

var sessions: Sessions = .{};
var wake: Handle = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        lib.log.fmt("Netstack: failed: {s}\n", .{@errorName(failure)});

        return 1;

    };

    return 0;

}

fn run() !void {

    wake = try sys.create(.notification, 0, 0);

    try link.attach(cap.netstack.net, cap.memory, wake);
    try start_timer_thread();

    tcp.init(&deliver_readiness);
    arp.set_learned_callback(&tcp.retry_pending_arp);

    try lib.stream.register_name("netstack", cap.server.endpoint);

    try sys.configure(cap.self_thread, .bound_notification, wake);

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(cap.server.endpoint, &in) catch continue;

        if (badge == cap.notification_wake) {

            pump();
            continue;

        }

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

        pump();

    }

}

// Runs after every wake, and after every handled request
fn pump() void {

    link.drain(&handle_frame);
    tcp.tick(lib.time.now_ms());

}

fn handle_frame(frame: []const u8) void {

    const parsed = eth.parse(frame) orelse return;

    switch (parsed.ethertype) {

        eth.ethertype_arp => arp.handle(parsed.payload),

        eth.ethertype_ipv4 => {

            const packet = ip.parse(parsed.payload) orelse return;

            switch (packet.protocol) {

                ip.protocol_icmp => icmp.handle(packet.src_ip, packet.payload),
                ip.protocol_tcp => tcp.handle_segment(packet.src_ip, packet.dst_ip, packet.payload),

                else => {},

            }

        },

        else => {},

    }

}

fn deliver_readiness(session_badge: u64, bits: u64) void {

    if (session_badge == 0) return;

    const session = sessions.find(session_badge) orelse return;

    if (session.extra.notification != 0) sys.notify(session.extra.notification, bits) catch {};

}

fn start_timer_thread() !void {

    const stack = try sys.create(.region, timer_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&timer_entry), base + timer_stack_pages * page_size);

    try sys.start(thread);

}

fn timer_entry() callconv(.c) noreturn {

    while (true) {

        lib.time.sleep_ms(tick_interval_ms);
        sys.notify(wake, timer_bit) catch {};

    }

}

// Request dispatch

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.socket.attach => attach(badge, in),
        proto.socket.detach => detach(badge),
        proto.socket.open => open_socket(badge, in, out),
        proto.socket.bind => bind_socket(badge, in),
        proto.socket.listen => listen_socket(badge, in),
        proto.socket.connect => connect_socket(badge, in),
        proto.socket.accept => accept_socket(badge, in, out),
        proto.socket.send => send_socket(badge, in, out),
        proto.socket.recv => recv_socket(badge, in, out),
        proto.socket.close => close_socket(badge, in),
        proto.socket.poll => poll_socket(badge, in, out),
        proto.socket.local_addr => local_addr_socket(badge, in, out),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.socket.interface_id;
    out.data[2] = proto.socket.version;

    return 0;

}

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 2) return -7;

    const session = sessions.open(badge);

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session.capacity = @intCast(in.data[1]);
    session.extra.notification = in.handles[1].handle;

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn detach(badge: u64) i64 {

    sessions.close(badge);

    return 0;

}

fn open_socket(badge: u64, in: *const Message, out: *Message) i64 {

    if (sessions.find(badge) == null) return -7;
    if (in.data[1] != proto.socket.kind_stream) return -7; // datagram sockets: not implemented in this pass

    const result = tcp.open(badge);

    if (result < 0) return result;

    out.data[1] = @intCast(result);

    return 0;

}

fn bind_socket(badge: u64, in: *const Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;

    return tcp.bind(index, @truncate(in.data[2]), @truncate(in.data[3]));

}

fn listen_socket(badge: u64, in: *const Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;

    return tcp.listen(index, in.data[2]);

}

fn connect_socket(badge: u64, in: *const Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;

    return tcp.connect(index, @truncate(in.data[2]), @truncate(in.data[3]));

}

fn accept_socket(badge: u64, in: *const Message, out: *Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;

    const result = tcp.accept(index, badge) catch |failure| return switch (failure) {

        error.WouldBlock => -5,
        else => -7,

    };

    out.data[1] = result.index;
    out.data[2] = result.addr;
    out.data[3] = result.port;

    return 0;

}

fn send_socket(badge: u64, in: *const Message, out: *Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;
    const session = sessions.find(badge) orelse return -7;
    const span = session_span(session, in.data[2], in.data[3]) orelse return -7;

    const result = tcp.send(index, span);

    if (result < 0) return result;

    out.data[1] = @intCast(result);

    return 0;

}

fn recv_socket(badge: u64, in: *const Message, out: *Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;
    const session = sessions.find(badge) orelse return -7;
    const span = session_span(session, in.data[2], in.data[3]) orelse return -7;

    const result = tcp.recv(index, span);

    if (result < 0) return result;

    out.data[1] = @intCast(result);

    return 0;

}

fn close_socket(badge: u64, in: *const Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;

    return tcp.close(index);

}

fn poll_socket(badge: u64, in: *const Message, out: *Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;
    const result = tcp.poll(index);

    if (result < 0) return result;

    out.data[1] = @intCast(result);

    return 0;

}

fn local_addr_socket(badge: u64, in: *const Message, out: *Message) i64 {

    const index = owned(badge, in.data[1]) orelse return -1;
    const info = tcp.local_addr(index) orelse return -7;

    out.data[1] = info.addr;
    out.data[2] = info.port;

    return 0;

}

/// A `sid` is a raw tcp.zig table index; every call after `open` must prove the caller's badge still owns it, so one client can never reach into another's socket.
fn owned(badge: u64, sid: u64) ?u16 {

    if (sid >= 0x1_0000) return null;

    const index: u16 = @intCast(sid);
    const who = tcp.owner(index) orelse return null;

    return if (who == badge) index else null;

}

fn session_span(session: *Session, offset: u64, length: u64) ?[]u8 {

    if (session.base == 0) return null;

    const start: usize = @intCast(offset);
    const len: usize = @intCast(length);

    if (start > session.capacity or len > session.capacity - start) return null;

    const bytes: [*]u8 = @ptrFromInt(session.base);

    return bytes[start .. start + len];

}
