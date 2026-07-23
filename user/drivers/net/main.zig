// virtio-net driver: an ordinary process holding its MMIO window and a DMA sub-grant, mirroring the block/audio driver design.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

// virtio-mmio registers (offsets from the transport base).

const reg_magic = 0x000;
const reg_version = 0x004;
const reg_device_id = 0x008;
const reg_device_features = 0x010;
const reg_device_features_sel = 0x014;
const reg_driver_features = 0x020;
const reg_driver_features_sel = 0x024;
const reg_queue_sel = 0x030;
const reg_queue_num_max = 0x034;
const reg_queue_num = 0x038;
const reg_queue_ready = 0x044;
const reg_queue_notify = 0x050;
const reg_interrupt_status = 0x060;
const reg_interrupt_ack = 0x064;
const reg_status = 0x070;
const reg_queue_desc_low = 0x080;
const reg_queue_desc_high = 0x084;
const reg_queue_driver_low = 0x090;
const reg_queue_driver_high = 0x094;
const reg_queue_device_low = 0x0a0;
const reg_queue_device_high = 0x0a4;
const reg_config = 0x100;

const virtio_magic: u32 = 0x7472_6976;
const device_id_net: u32 = 1;

const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

// Feature bits we ask for: MAC (config space carries the assigned MAC) and STATUS (link up/down)

const feature_mac: u32 = 1 << 5;
const feature_status: u32 = 1 << 16;
const feature_version_1: u32 = 1 << 0; // bit 32 overall, word 1 bit 0

const queue_rx: u16 = 0;
const queue_tx: u16 = 1;
const queue_size = 32;

const descriptor_next: u16 = 1;
const descriptor_write: u16 = 2;

const Descriptor = extern struct {

    addr: u64,
    len: u32,

    flags: u16,
    next: u16,

};

const Avail = extern struct {

    flags: u16,
    idx: u16,

    ring: [queue_size]u16,

};

const UsedElement = extern struct {

    id: u32,
    len: u32,

};

const Used = extern struct {

    flags: u16,
    idx: u16,

    ring: [queue_size]UsedElement,

};

const Queue = struct {

    index: u16,
    base: usize,
    physical: u64,
    last_used: u16 = 0,

};

// The virtio-net per-packet header (modern layout, 12 bytes). It is always present once VERSION_1 is negotiated, even with no offload features.

const NetHdr = extern struct {

    flags: u8,
    gso_type: u8,

    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
    num_buffers: u16,

};

const net_hdr_size = @sizeOf(NetHdr);

const page_size = 4096;
const queue_bytes = 2 * page_size;
const avail_offset = queue_size * @sizeOf(Descriptor);
const used_offset = page_size;

const rx_slot_size = 2048;
const rx_pool = queue_size;

const rx_queue_off = 0;
const tx_queue_off = queue_bytes;
const rx_buffers_off = 2 * queue_bytes;
const rx_buffers_bytes = rx_pool * rx_slot_size;
const tx_hdr_off = rx_buffers_off + rx_buffers_bytes;
const tx_frame_off = tx_hdr_off + net_hdr_size;
const tx_frame_capacity = lib.netframe.max_frame;
const dma_bytes = tx_frame_off + tx_frame_capacity;

var regs: usize = 0;
var dma_base: usize = 0;
var dma_physical: u64 = 0;

var rx: Queue = undefined;
var tx: Queue = undefined;

var completion: Handle = 0;

var mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var status_negotiated = false;
var link_enabled = true;
var rx_bytes: u64 = 0;
var tx_bytes: u64 = 0;

// The one attached client (the netstack): its RX frame ring, TX staging buffer, and RX-ready Notification.

var client_ring: ?lib.netframe.Ring = null;
var client_ring_base: usize = 0;
var client_tx_base: usize = 0;
var client_notification: Handle = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        log_two("Net: virtio-net driver failed: ", @errorName(failure));

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    const window = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);
    regs = window + @as(usize, @intCast(lib.start.word(3)));

    completion = try sys.create(.notification, 0, 0);
    try sys.bind(cap.driver.interrupt, completion, 1);

    const dma = try sys.create_dma(dma_bytes, cap.driver.dma);
    dma_base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);
    dma_physical = dma.physical_base;

    const dma_bytes_slice: [*]u8 = @ptrFromInt(dma_base);
    @memset(dma_bytes_slice[0..dma_bytes], 0);

    try init_device();
    arm_rx();

    // Register only after the device is live so a failed bind never leaves a dead "net" name.
    try lib.stream.register_name("net", cap.driver.endpoint);

    try sys.configure(cap.self_thread, .bound_notification, completion);

    log_one("Net: virtio-net driver ... Loaded\n");

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(cap.driver.endpoint, &in) catch continue;

        if (badge == cap.notification_wake) {

            drain_rx();
            continue;

        }

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

        drain_rx();

    }

}

fn init_device() !void {

    if (reg_read(reg_magic) != virtio_magic) return error.NotFound;
    if (reg_read(reg_device_id) != device_id_net) return error.NotFound;

    const version = reg_read(reg_version);

    if (version != 1 and version != 2) return error.NotFound;

    reg_write(reg_status, 0);
    reg_write(reg_status, status_acknowledge);
    reg_write(reg_status, status_acknowledge | status_driver);

    if (version != 2) return error.NotFound; // modern-only: MMIO v2 64-bit queue addressing, as block/audio require.

    reg_write(reg_device_features_sel, 0);
    const device_word0 = reg_read(reg_device_features);
    reg_write(reg_driver_features_sel, 0);
    reg_write(reg_driver_features, device_word0 & (feature_mac | feature_status));

    reg_write(reg_device_features_sel, 1);
    const device_word1 = reg_read(reg_device_features);
    reg_write(reg_driver_features_sel, 1);
    reg_write(reg_driver_features, device_word1 & feature_version_1);

    if (device_word1 & feature_version_1 == 0) return error.NotFound;

    status_negotiated = device_word0 & feature_status != 0;

    reg_write(reg_status, status_acknowledge | status_driver | status_features_ok);

    if (reg_read(reg_status) & status_features_ok == 0) return error.Invalid;

    rx = try init_queue(queue_rx, rx_queue_off);
    tx = try init_queue(queue_tx, tx_queue_off);

    reg_write(reg_status, reg_read(reg_status) | status_driver_ok);

    if (device_word0 & feature_mac != 0) {

        for (0..6) |index| mac[index] = byte_read(reg_config + index);

    }

}

fn init_queue(index: u16, offset: usize) !Queue {

    reg_write(reg_queue_sel, index);

    if (reg_read(reg_queue_num_max) < queue_size) return error.Invalid;

    const physical = dma_physical + offset;
    const available = physical + avail_offset;
    const used = physical + used_offset;

    reg_write(reg_queue_num, queue_size);
    reg_write(reg_queue_desc_low, @truncate(physical));
    reg_write(reg_queue_desc_high, @truncate(physical >> 32));
    reg_write(reg_queue_driver_low, @truncate(available));
    reg_write(reg_queue_driver_high, @truncate(available >> 32));
    reg_write(reg_queue_device_low, @truncate(used));
    reg_write(reg_queue_device_high, @truncate(used >> 32));
    reg_write(reg_queue_ready, 1);

    return .{ .index = index, .base = dma_base + offset, .physical = physical };

}

// Posts every RX buffer before traffic can arrive

fn arm_rx() void {

    const descriptors: [*]volatile Descriptor = @ptrFromInt(rx.base);
    const avail: *volatile Avail = @ptrFromInt(rx.base + avail_offset);

    for (0..rx_pool) |slot| {

        descriptors[slot] = .{

            .addr = dma_physical + rx_buffers_off + slot * rx_slot_size,
            .len = rx_slot_size,

            .flags = descriptor_write,
            .next = 0,

        };

        avail.ring[slot] = @intCast(slot);

    }

    barrier();

    avail.idx = rx_pool;

    barrier();

    reg_write(reg_queue_notify, queue_rx);

}

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.net.attach => attach(badge, in),
        proto.net.mac_address => mac_address(out),
        proto.net.transmit => transmit(in.data[1]),
        proto.net.link_status => link_status(out),
        proto.net.set_enabled => set_enabled(in.data[1]),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.net.interface_id;
    out.data[2] = proto.net.version;

    return 0;

}

// Note: a fresh attach replaces whatever was there before.

fn attach(_: u64, in: *const Message) i64 {

    if (in.handle_count < 3) return -7;

    const tx_capacity: usize = @intCast(in.data[2]);

    if (tx_capacity == 0 or tx_capacity > tx_frame_capacity) return -7;

    if (client_ring_base != 0) sys.unmap(cap.self_space, client_ring_base) catch {};
    if (client_tx_base != 0) sys.unmap(cap.self_space, client_tx_base) catch {};
    if (client_notification != 0) sys.close(client_notification) catch {};

    const ring_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    const tx_base = sys.map(cap.self_space, in.handles[1].handle, 0, sys.read) catch {

        sys.unmap(cap.self_space, ring_base) catch {};
        return -7;

    };

    client_ring = lib.netframe.Ring.open(ring_base);
    client_ring_base = ring_base;
    client_tx_base = tx_base;
    client_notification = in.handles[2].handle;

    sys.close(in.handles[0].handle) catch {};
    sys.close(in.handles[1].handle) catch {};

    return 0;

}

fn mac_address(out: *Message) i64 {

    out.data[1] = @as(u64, mac[0]) | (@as(u64, mac[1]) << 8) | (@as(u64, mac[2]) << 16) | (@as(u64, mac[3]) << 24);
    out.data[2] = @as(u64, mac[4]) | (@as(u64, mac[5]) << 8);

    return 0;

}

fn link_status(out: *Message) i64 {

    var physical: u64 = 1;

    if (status_negotiated) {

        const low = byte_read(reg_config + 6);
        const high = byte_read(reg_config + 7);
        const link_up_bit: u16 = 1;

        physical = if ((@as(u16, high) << 8 | low) & link_up_bit != 0) 1 else 0;

    }

    // Virtio status can stick at 0 under QEMU user-net while frames still flow; treat seen traffic as up.
    const up: u64 = if (physical != 0 or rx_bytes > 0 or tx_bytes > 0) 1 else 0;

    out.data[1] = up;
    out.data[2] = rx_bytes;
    out.data[3] = tx_bytes;
    out.data[4] = if (link_enabled) 1 else 0;

    return 0;

}

fn set_enabled(value: u64) i64 {

    link_enabled = value != 0;

    return 0;

}

fn transmit(length: u64) i64 {

    if (!link_enabled) return -7;
    if (client_tx_base == 0) return -7;
    if (length == 0 or length > tx_frame_capacity) return -7;

    const len: usize = @intCast(length);

    acknowledge_device_status();

    const hdr: *volatile NetHdr = @ptrFromInt(dma_base + tx_hdr_off);
    hdr.* = .{

        .flags = 0,
        .gso_type = 0,

        .hdr_len = 0,
        .gso_size = 0,
        .csum_start = 0,
        .csum_offset = 0,
        .num_buffers = 0,

    };

    const source: [*]const u8 = @ptrFromInt(client_tx_base);
    const dest: [*]u8 = @ptrFromInt(dma_base + tx_frame_off);

    @memcpy(dest[0..len], source[0..len]);

    const descriptors: [*]volatile Descriptor = @ptrFromInt(tx.base);

    descriptors[0] = .{ .addr = dma_physical + tx_hdr_off, .len = net_hdr_size, .flags = descriptor_next, .next = 1 };
    descriptors[1] = .{ .addr = dma_physical + tx_frame_off, .len = @intCast(len), .flags = 0, .next = 0 };

    const avail: *volatile Avail = @ptrFromInt(tx.base + avail_offset);

    avail.ring[avail.idx % queue_size] = 0;

    barrier();

    avail.idx +%= 1;

    barrier();

    reg_write(reg_queue_notify, queue_tx);

    const used: *volatile Used = @ptrFromInt(tx.base + used_offset);

    while (true) {

        barrier();

        if (used.idx != tx.last_used) {

            tx.last_used = used.idx;

            acknowledge_device_status();
            _ = sys.acknowledge(cap.driver.interrupt) catch {};

            tx_bytes +%= len;

            return 0;

        }

        drain_rx();

        _ = sys.wait(completion) catch return -7;

        acknowledge_device_status();
        _ = sys.acknowledge(cap.driver.interrupt) catch {};

    }

}

fn drain_rx() void {

    _ = sys.acknowledge(cap.driver.interrupt) catch {};

    acknowledge_device_status();

    const avail: *volatile Avail = @ptrFromInt(rx.base + avail_offset);
    const used: *volatile Used = @ptrFromInt(rx.base + used_offset);

    var pushed = false;
    var reposted = false;

    while (true) {

        barrier();

        if (used.idx == rx.last_used) break;

        const element = used.ring[rx.last_used % queue_size];

        rx.last_used +%= 1;

        if (element.len > net_hdr_size) {

            const slot = element.id % rx_pool;
            const frame_len: usize = @intCast(element.len - net_hdr_size);
            const source: [*]const u8 = @ptrFromInt(dma_base + rx_buffers_off + slot * rx_slot_size + net_hdr_size);

            rx_bytes +%= frame_len;

            if (link_enabled) {

                if (client_ring) |ring| {

                    if (ring.push(source[0..@min(frame_len, lib.netframe.max_frame)])) pushed = true;

                }

            }

        }

        // Hand the buffer straight back to the device (its descriptor still points at the same slot, unchanged).

        avail.ring[avail.idx % queue_size] = @intCast(element.id);

        barrier();

        avail.idx +%= 1;

        reposted = true;

    }

    if (reposted) reg_write(reg_queue_notify, queue_rx);

    if (pushed and client_notification != 0) {

        sys.notify(client_notification, proto.net.rx_bit) catch {};

    }

}

fn acknowledge_device_status() void {

    const status = reg_read(reg_interrupt_status);

    if (status != 0) reg_write(reg_interrupt_ack, status);

}

fn barrier() void {

    asm volatile ("dsb sy" ::: .{ .memory = true });

}

fn reg_read(offset: usize) u32 {

    const register: *volatile u32 = @ptrFromInt(regs + offset);

    return register.*;

}

fn reg_write(offset: usize, value: u32) void {

    const register: *volatile u32 = @ptrFromInt(regs + offset);

    register.* = value;

}

fn byte_read(offset: usize) u8 {

    const register: *volatile u8 = @ptrFromInt(regs + offset);

    return register.*;

}

fn log_one(text: []const u8) void {

    lib.log.line(text);

}

fn log_two(text: []const u8, extra: []const u8) void {

    lib.log.fmt("{s}{s}\n", .{ text, extra });

}
