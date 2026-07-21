// virtio-rng driver: entropy device id 4, one virtqueue of random bytes.

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

const virtio_magic: u32 = 0x7472_6976;
const device_id_rng: u32 = 4;

const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

const feature_version_1: u32 = 1 << 0;

const queue_size = 8;
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

const page_size = 4096;
const dma_pages = 3;
const avail_offset = queue_size * @sizeOf(Descriptor);
const used_offset = page_size;
const entropy_offset = 2 * page_size;
const entropy_capacity = page_size;

var regs: usize = 0;
var dma_base: usize = 0;
var dma_physical: u64 = 0;
var last_used: u16 = 0;
var completion: Handle = 0;

const completion_bit: u64 = 1;

var session_base: usize = 0;
var session_capacity: usize = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        lib.log.fmt("Rng: failed: {s}\n", .{@errorName(failure)});

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    const window = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);
    regs = window + @as(usize, @intCast(lib.start.word(3)));

    completion = try sys.create(.notification, 0, 0);
    try sys.bind(cap.driver.interrupt, completion, completion_bit);

    const dma = try sys.create_dma(dma_pages * page_size, cap.driver.dma);
    dma_base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);
    dma_physical = dma.physical_base;

    const dma_bytes: [*]u8 = @ptrFromInt(dma_base);
    @memset(dma_bytes[0 .. dma_pages * page_size], 0);

    try init_device();

    lib.log.fmt("Rng: virtio-rng driver ... Loaded\n", .{});

    var in = Message.zeroed;

    while (true) {

        const badge = try sys.receive(cap.driver.endpoint, &in);

        if (badge == cap.notification_wake) continue;

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

    }

}

fn init_device() !void {

    if (reg_read(reg_magic) != virtio_magic) return error.NotFound;
    if (reg_read(reg_device_id) != device_id_rng) return error.NotFound;

    const version = reg_read(reg_version);

    if (version != 2) return error.NotFound;

    reg_write(reg_status, 0);
    reg_write(reg_status, status_acknowledge);
    reg_write(reg_status, status_acknowledge | status_driver);

    reg_write(reg_device_features_sel, 1);
    const device_word1 = reg_read(reg_device_features);
    reg_write(reg_driver_features_sel, 1);
    reg_write(reg_driver_features, device_word1 & feature_version_1);

    if (device_word1 & feature_version_1 == 0) return error.NotFound;

    reg_write(reg_driver_features_sel, 0);
    reg_write(reg_driver_features, 0);

    reg_write(reg_status, status_acknowledge | status_driver | status_features_ok);

    if (reg_read(reg_status) & status_features_ok == 0) return error.Invalid;

    reg_write(reg_queue_sel, 0);

    if (reg_read(reg_queue_num_max) < queue_size) return error.Invalid;

    const physical = dma_physical;
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

    reg_write(reg_status, reg_read(reg_status) | status_driver_ok);

}

fn dispatch(method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.entropy.attach => attach(in),
        proto.entropy.read => read_entropy(in, out),
        proto.entropy.detach => detach(),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.entropy.interface_id;
    out.data[2] = proto.entropy.version;

    return 0;

}

fn attach(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    session_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session_capacity = @intCast(in.data[1]);

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn detach() i64 {

    if (session_base != 0) sys.unmap(cap.self_space, session_base) catch {};

    session_base = 0;
    session_capacity = 0;

    return 0;

}

fn read_entropy(in: *const Message, out: *Message) i64 {

    if (session_base == 0) return -7;

    const want: usize = @min(@as(usize, @intCast(in.data[1])), session_capacity, entropy_capacity);

    if (want == 0) {

        out.data[1] = 0;

        return 0;

    }

    const filled = fill(want) catch return -7;
    const dest: [*]u8 = @ptrFromInt(session_base);
    const source: [*]const u8 = @ptrFromInt(dma_base + entropy_offset);

    @memcpy(dest[0..filled], source[0..filled]);

    out.data[1] = filled;

    return 0;

}

fn fill(want: usize) !usize {

    const descriptors: [*]volatile Descriptor = @ptrFromInt(dma_base);
    const avail: *volatile Avail = @ptrFromInt(dma_base + avail_offset);
    const used: *volatile Used = @ptrFromInt(dma_base + used_offset);

    const slot: u16 = 0;

    descriptors[slot] = .{

        .addr = dma_physical + entropy_offset,
        .len = @intCast(want),
        .flags = descriptor_write,
        .next = 0,

    };

    const idx = avail.idx;

    avail.ring[idx % queue_size] = slot;

    barrier();

    avail.idx = idx +% 1;

    barrier();

    reg_write(reg_queue_notify, 0);

    // Wait for the device to fill the buffer.
    var spins: u32 = 0;

    while (used.idx == last_used) {

        _ = sys.wait(completion) catch {};

        // Ack interrupt.
        const status = reg_read(reg_interrupt_status);

        if (status != 0) reg_write(reg_interrupt_ack, status);

        spins += 1;

        if (spins > 1000) return error.Timeout;

    }

    const elem = used.ring[last_used % queue_size];

    last_used +%= 1;

    return @min(want, elem.len);

}

fn reg_read(offset: usize) u32 {

    const ptr: *volatile u32 = @ptrFromInt(regs + offset);

    return ptr.*;

}

fn reg_write(offset: usize, value: u32) void {

    const ptr: *volatile u32 = @ptrFromInt(regs + offset);

    ptr.* = value;

}

fn barrier() void {

    asm volatile ("dmb sy" ::: .{ .memory = true });

}
