// virtio-blk driver (07-userspace-ddd.md Section 5.2): an ordinary process holding its MMIO window and a DMA sub-grant.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

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
const reg_guest_page_size = 0x028; // legacy only
const reg_queue_sel = 0x030;
const reg_queue_num_max = 0x034;
const reg_queue_num = 0x038;
const reg_queue_align = 0x03c; // legacy only
const reg_queue_pfn = 0x040; // legacy only
const reg_queue_ready = 0x044; // modern only
const reg_queue_notify = 0x050;
const reg_interrupt_status = 0x060;
const reg_interrupt_ack = 0x064;
const reg_status = 0x070;
const reg_queue_desc_low = 0x080; // modern only
const reg_queue_desc_high = 0x084;
const reg_queue_driver_low = 0x090;
const reg_queue_driver_high = 0x094;
const reg_queue_device_low = 0x0a0;
const reg_queue_device_high = 0x0a4;
const reg_config = 0x100; // virtio-blk: capacity in sectors as a le64

const virtio_magic: u32 = 0x7472_6976; // "virt"
const device_id_block: u32 = 2;

const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

// The split virtqueue (one queue, 3-descriptor request chains, one request in flight at a time).

const queue_size = 8;

const descriptor_next: u16 = 1;
const descriptor_write: u16 = 2;
const avail_no_interrupt: u16 = 1;

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

// virtio-blk request layout.

const request_read: u32 = 0;
const request_write: u32 = 1;

const RequestHeader = extern struct {

    kind: u32,
    reserved: u32,

    sector: u64,

};

// DMA region layout: descriptors + avail on page 0, used on page 1 (the legacy alignment rule), the request
// header, status byte, and one-sector bounce buffer on page 2.

const page_size = 4096;
const dma_pages = 3;

const avail_offset = queue_size * @sizeOf(Descriptor);
const used_offset = page_size;
const header_offset = 2 * page_size;
const status_offset = header_offset + @sizeOf(RequestHeader);
const data_offset = header_offset + 512;

const sector_size = proto.block.sector_size;

var regs: usize = 0;
var dma_base: usize = 0;
var dma_physical: u64 = 0;

var sector_count: u64 = 0;
var last_used: u16 = 0;

// Per-client shared buffers (05-server-protocol.md): attached once, then reused by every read/write.

const max_sessions = 16;

const Session = struct {

    base: usize = 0,
    capacity: usize = 0,

};

var sessions: [max_sessions]Session = [_]Session{.{}} ** max_sessions;

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        log_two("Block: virtio-blk driver failed: ", @errorName(failure));

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    // Flint grants the page-aligned MMIO window; the transport's in-page offset rides in init word 3.

    const window = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);
    regs = window + @as(usize, @intCast(lib.start.word(3)));

    const dma = try sys.create_dma(dma_pages * page_size, cap.driver.dma);
    dma_base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);
    dma_physical = dma.physical_base;

    // Fresh frames are not zeroed; the rings (and their idx fields) must start clear.

    const dma_bytes: [*]u8 = @ptrFromInt(dma_base);
    @memset(dma_bytes[0 .. dma_pages * page_size], 0);

    const avail: *volatile Avail = @ptrFromInt(dma_base + avail_offset);
    avail.flags = avail_no_interrupt;

    try init_device();

    log_one("Block: virtio-blk driver ... Loaded\n");

    var in = Message.zeroed;

    while (true) {

        const badge = try sys.receive(cap.driver.endpoint, &in);

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

    }

}

fn init_device() !void {

    if (reg_read(reg_magic) != virtio_magic) return error.NotFound;
    if (reg_read(reg_device_id) != device_id_block) return error.NotFound;

    const version = reg_read(reg_version);

    if (version != 1 and version != 2) return error.NotFound;

    reg_write(reg_status, 0); // reset
    reg_write(reg_status, status_acknowledge);
    reg_write(reg_status, status_acknowledge | status_driver);

    if (version == 2) {

        reg_write(reg_device_features_sel, 0);
        _ = reg_read(reg_device_features);
        reg_write(reg_driver_features_sel, 0);
        reg_write(reg_driver_features, 0);

        reg_write(reg_device_features_sel, 1);
        _ = reg_read(reg_device_features);
        reg_write(reg_driver_features_sel, 1);
        reg_write(reg_driver_features, 0);

        reg_write(reg_status, status_acknowledge | status_driver | status_features_ok);

        if (reg_read(reg_status) & status_features_ok == 0) return error.NotFound;

    } else {

        _ = reg_read(reg_device_features);
        reg_write(reg_driver_features, 0); // GuestFeatures: nothing negotiated
        reg_write(reg_guest_page_size, page_size);

    }

    reg_write(reg_queue_sel, 0);

    if (reg_read(reg_queue_num_max) < queue_size) return error.Invalid;

    reg_write(reg_queue_num, queue_size);

    if (version == 2) {

        reg_write(reg_queue_desc_low, @truncate(dma_physical));
        reg_write(reg_queue_desc_high, @truncate(dma_physical >> 32));
        reg_write(reg_queue_driver_low, @truncate(dma_physical + avail_offset));
        reg_write(reg_queue_driver_high, @truncate((dma_physical + avail_offset) >> 32));
        reg_write(reg_queue_device_low, @truncate(dma_physical + used_offset));
        reg_write(reg_queue_device_high, @truncate((dma_physical + used_offset) >> 32));
        reg_write(reg_queue_ready, 1);

    } else {

        reg_write(reg_queue_align, page_size);
        reg_write(reg_queue_pfn, @truncate(dma_physical / page_size));

    }

    reg_write(reg_status, reg_read(reg_status) | status_driver_ok);

    sector_count = @as(u64, reg_read(reg_config)) | (@as(u64, reg_read(reg_config + 4)) << 32);

    if (sector_count == 0) return error.NotFound;

}

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.block.read_sector => read_sector(badge, in.data[1], in.data[2]),
        proto.block.write_sector => write_sector(badge, in.data[1], in.data[2]),
        proto.block.capacity => capacity(out),
        proto.block.attach => attach(badge, in),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.block.interface_id;
    out.data[2] = proto.block.version;

    return 0;

}

fn capacity(out: *Message) i64 {

    out.data[1] = sector_count;

    return 0;

}

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    const session = session_for(badge) orelse return -7;

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session.capacity = @intCast(in.data[1]);

    return 0;

}

fn read_sector(badge: u64, sector: u64, offset: u64) i64 {

    const span = session_span(badge, offset) orelse return -7;

    if (sector >= sector_count) return -7;

    const status = transfer(request_read, sector);

    if (status != 0) return status;

    @memcpy(span, bounce()[0..sector_size]);

    return 0;

}

fn write_sector(badge: u64, sector: u64, offset: u64) i64 {

    const span = session_span(badge, offset) orelse return -7;

    if (sector >= sector_count) return -7;

    @memcpy(bounce()[0..sector_size], span);

    return transfer(request_write, sector);

}

// Submit one 3-descriptor request chain (header, one sector, status byte) and sleep until the device completes it.

fn transfer(kind: u32, sector: u64) i64 {

    acknowledge_device_status();

    const header: *volatile RequestHeader = @ptrFromInt(dma_base + header_offset);
    header.* = .{

        .kind = kind,
        .reserved = 0,

        .sector = sector,

    };

    const status_byte: *volatile u8 = @ptrFromInt(dma_base + status_offset);
    status_byte.* = 0xff;

    const descriptors: [*]volatile Descriptor = @ptrFromInt(dma_base);
    const data_write_flag: u16 = if (kind == request_read) descriptor_write else 0;

    descriptors[0] = .{ .addr = dma_physical + header_offset, .len = @sizeOf(RequestHeader), .flags = descriptor_next, .next = 1 };
    descriptors[1] = .{ .addr = dma_physical + data_offset, .len = sector_size, .flags = descriptor_next | data_write_flag, .next = 2 };
    descriptors[2] = .{ .addr = dma_physical + status_offset, .len = 1, .flags = descriptor_write, .next = 0 };

    const avail: *volatile Avail = @ptrFromInt(dma_base + avail_offset);

    avail.ring[avail.idx % queue_size] = 0;

    barrier();

    avail.idx +%= 1;

    barrier();

    reg_write(reg_queue_notify, 0);

    const used: *volatile Used = @ptrFromInt(dma_base + used_offset);

    var polls: usize = 0;

    while (polls < 1_000_000) : (polls += 1) {

        barrier();

        if (used.idx == last_used) continue;

        last_used = used.idx;
        acknowledge_device_status();

        return if (status_byte.* == 0) 0 else -7;

    }

    acknowledge_device_status();

    return -7;

}

fn acknowledge_device_status() void {

    const status = reg_read(reg_interrupt_status);

    if (status != 0) reg_write(reg_interrupt_ack, status);

}

fn bounce() []u8 {

    const bytes: [*]u8 = @ptrFromInt(dma_base + data_offset);

    return bytes[0..sector_size];

}

fn session_span(badge: u64, offset: u64) ?[]u8 {

    const session = session_for(badge) orelse return null;

    if (session.base == 0) return null;
    if (offset > session.capacity or sector_size > session.capacity - offset) return null;

    const buffer: [*]u8 = @ptrFromInt(session.base);

    return buffer[@intCast(offset)..@intCast(offset + sector_size)];

}

fn session_for(badge: u64) ?*Session {

    if (badge >= max_sessions) return null;

    return &sessions[@intCast(badge)];

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

// Boot logging goes through the console service; failures to log are ignored.

fn log_one(text: []const u8) void {

    lib.log.line(text);

}

fn log_two(text: []const u8, extra: []const u8) void {

    lib.log.fmt("{s}{s}\n", .{ text, extra });

}
