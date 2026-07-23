const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

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
const reg_config = 0x100;

const virtio_magic: u32 = 0x7472_6976;
const device_id_sound: u32 = 25;

const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

const queue_control: u16 = 0;
const queue_event: u16 = 1;
const queue_tx: u16 = 2;
const queue_rx: u16 = 3;
const queue_size = 8;
const descriptor_next: u16 = 1;
const descriptor_write: u16 = 2;
const page_size = 4096;

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

const Header = extern struct {

    code: u32,

};

const PcmSetParams = extern struct {

    header: Header,
    stream_id: u32,
    buffer_bytes: u32,
    period_bytes: u32,
    features: u32,
    channels: u8,
    format: u8,
    rate: u8,
    padding: u8,

};

const PcmHeader = extern struct {

    header: Header,
    stream_id: u32,

};

const PcmXfer = extern struct {

    stream_id: u32,

};

const PcmStatus = extern struct {

    status: u32,
    latency_bytes: u32,

};

const command_set_params: u32 = 0x0101;
const command_prepare: u32 = 0x0102;
const command_release: u32 = 0x0103;
const command_start: u32 = 0x0104;
const command_stop: u32 = 0x0105;
const response_ok: u32 = 0x8000;

const format_s16: u8 = 5;
const stream_id: u32 = 0;

const queue_bytes = 2 * page_size;
const control_offset = 4 * queue_bytes;
const tx_offset = control_offset + page_size;
const payload_offset = tx_offset + page_size;
const dma_bytes = payload_offset + proto.audio.max_write;

// Name-service lookups mint badges from 64 upward. Sessions must be keyed by badge, not used as an index.
const max_sessions = 16;
const Sessions = lib.session.Sessions(struct {}, max_sessions);
const Session = Sessions.Session;

var sessions: Sessions = .{};

var regs: usize = 0;
var dma_base: usize = 0;
var dma_physical: u64 = 0;
var completion: cap.Handle = 0;
var control: Queue = undefined;
var tx: Queue = undefined;
var running = false;
var muted = false;
var frame_size: usize = 0;
var sample_rate: u32 = 0;
var last_latency: u32 = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        lib.log.fmt("Audio: virtio-sound driver failed: {s}\n", .{@errorName(failure)});
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

    const bytes: [*]u8 = @ptrFromInt(dma_base);
    @memset(bytes[0..dma_bytes], 0);

    try init_device();

    // Register only after the device is live so a failed bind never leaves a dead "audio" name that hangs clients.
    try lib.stream.register_name("audio", cap.driver.endpoint);

    lib.log.line("Audio: virtio-sound driver ... Loaded\n");
    ipc.serve(cap.driver.endpoint, dispatch);

}

fn init_device() !void {

    if (reg_read(reg_magic) != virtio_magic) return error.NotFound;
    if (reg_read(reg_device_id) != device_id_sound) return error.NotFound;

    const version = reg_read(reg_version);

    if (version != 2) return error.NotFound;
    if (reg_read(reg_config + 4) == 0) return error.NotFound;

    reg_write(reg_status, 0);
    reg_write(reg_status, status_acknowledge);
    reg_write(reg_status, status_acknowledge | status_driver);

    reg_write(reg_device_features_sel, 0);
    _ = reg_read(reg_device_features);
    reg_write(reg_driver_features_sel, 0);
    reg_write(reg_driver_features, 0);

    reg_write(reg_device_features_sel, 1);
    _ = reg_read(reg_device_features);
    reg_write(reg_driver_features_sel, 1);
    reg_write(reg_driver_features, 1); // VIRTIO_F_VERSION_1

    reg_write(reg_status, status_acknowledge | status_driver | status_features_ok);

    if (reg_read(reg_status) & status_features_ok == 0) return error.Invalid;

    control = try init_queue(queue_control, 0);
    _ = try init_queue(queue_event, queue_bytes);
    tx = try init_queue(queue_tx, 2 * queue_bytes);
    _ = try init_queue(queue_rx, 3 * queue_bytes);

    reg_write(reg_status, reg_read(reg_status) | status_driver_ok);

}

fn init_queue(index: u16, offset: usize) !Queue {

    reg_write(reg_queue_sel, index);

    if (reg_read(reg_queue_num_max) < queue_size) return error.Invalid;

    const physical = dma_physical + offset;
    const available = physical + queue_size * @sizeOf(Descriptor);
    const used = physical + page_size;

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

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.audio.attach => attach(badge, in),
        proto.audio.configure => configure(in.data[1], in.data[2], in.data[3]),
        proto.audio.write => write_audio(badge, in.data[1], in.data[2], out),
        proto.audio.drain => drain_stream(),
        proto.audio.stop => stop_stream(),
        proto.audio.set_mute => set_mute(in.data[1]),
        proto.audio.get_mute => get_mute(out),
        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.audio.interface_id;
    out.data[2] = proto.audio.version;

    return 0;

}

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    const client = sessions.open(badge);

    client.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read) catch return -7;
    client.capacity = @intCast(in.data[1]);

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn configure(rate: u64, channels: u64, bits: u64) i64 {

    if (bits != proto.audio.format_s16_le) return -7;
    if (channels != 1 and channels != 2) return -7;

    const rate_code = rate_code_for(rate) orelse return -7;

    if (running and stop_stream() != 0) return -7;

    const period: u32 = 4 * 1024;
    const buffer: u32 = period * 4;

    const params: *volatile PcmSetParams = @ptrFromInt(dma_base + control_offset);
    params.* = .{

        .header = .{ .code = command_set_params },
        .stream_id = stream_id,
        .buffer_bytes = buffer,
        .period_bytes = period,
        .features = 0,
        .channels = @intCast(channels),
        .format = format_s16,
        .rate = rate_code,
        .padding = 0,

    };

    if (control_command(@sizeOf(PcmSetParams)) != 0) return -7;

    if (simple_command(command_prepare) != 0) return -7;
    if (simple_command(command_start) != 0) return -7;

    frame_size = @intCast(channels * 2);
    sample_rate = @intCast(rate);
    last_latency = 0;
    running = true;

    return 0;

}

fn write_audio(badge: u64, offset: u64, length: u64, out: *Message) i64 {

    if (!running or frame_size == 0) return -7;
    if (length == 0 or length > proto.audio.max_write) return -7;
    if (length % frame_size != 0) return -7;

    const client = session_for(badge) orelse return -7;

    if (client.base == 0 or offset > client.capacity or length > client.capacity - offset) return -7;

    const source: [*]const u8 = @ptrFromInt(client.base + @as(usize, @intCast(offset)));
    const target: [*]u8 = @ptrFromInt(dma_base + payload_offset);

    if (muted) {

        @memset(target[0..@intCast(length)], 0);

    } else {

        @memcpy(target[0..@intCast(length)], source[0..@intCast(length)]);

    }

    const xfer: *volatile PcmXfer = @ptrFromInt(dma_base + tx_offset);
    xfer.* = .{ .stream_id = stream_id };

    const result: *volatile PcmStatus = @ptrFromInt(dma_base + tx_offset + @sizeOf(PcmXfer));
    result.* = .{ .status = 0, .latency_bytes = 0 };

    submit(&tx, &.{

        .{ .addr = dma_physical + tx_offset, .len = @sizeOf(PcmXfer), .flags = descriptor_next, .next = 1 },
        .{ .addr = dma_physical + payload_offset, .len = @intCast(length), .flags = descriptor_next, .next = 2 },
        .{ .addr = dma_physical + tx_offset + @sizeOf(PcmXfer), .len = @sizeOf(PcmStatus), .flags = descriptor_write, .next = 0 },

    }) catch return -7;

    if (result.status != response_ok) return -7;

    last_latency = result.latency_bytes;
    out.data[1] = length;

    return 0;

}

fn drain_stream() i64 {

    if (!running or sample_rate == 0 or frame_size == 0) return 0;

    const bytes_per_ms = @max(@as(u32, 1), (sample_rate * @as(u32, @intCast(frame_size))) / 1000);
    const remaining = if (last_latency != 0) last_latency else @as(u32, 16 * 1024);
    const wait_ms = @min(remaining / bytes_per_ms + 50, 5_000);

    lib.time.sleep_ms(wait_ms);

    return 0;

}

fn stop_stream() i64 {

    if (!running) return 0;

    if (simple_command(command_stop) != 0) return -7;
    if (simple_command(command_release) != 0) return -7;

    running = false;
    frame_size = 0;
    sample_rate = 0;
    last_latency = 0;

    return 0;

}

fn set_mute(value: u64) i64 {

    muted = value != 0;

    return 0;

}

fn get_mute(out: *Message) i64 {

    out.data[1] = if (muted) 1 else 0;

    return 0;

}

fn simple_command(code: u32) i64 {

    const command: *volatile PcmHeader = @ptrFromInt(dma_base + control_offset);
    command.* = .{ .header = .{ .code = code }, .stream_id = stream_id };

    return control_command(@sizeOf(PcmHeader));

}

fn control_command(length: u32) i64 {

    const response: *volatile Header = @ptrFromInt(dma_base + control_offset + 128);
    response.* = .{ .code = 0 };

    submit(&control, &.{

        .{ .addr = dma_physical + control_offset, .len = length, .flags = descriptor_next, .next = 1 },
        .{ .addr = dma_physical + control_offset + 128, .len = @sizeOf(Header), .flags = descriptor_write, .next = 0 },

    }) catch return -7;

    return if (response.code == response_ok) 0 else -7;

}

fn submit(queue: *Queue, chain: []const Descriptor) !void {

    acknowledge_device();

    const descriptors: [*]volatile Descriptor = @ptrFromInt(queue.base);

    for (chain, 0..) |descriptor, index| descriptors[index] = descriptor;

    const available: *volatile Avail = @ptrFromInt(queue.base + queue_size * @sizeOf(Descriptor));
    available.ring[available.idx % queue_size] = 0;

    barrier();
    available.idx +%= 1;
    barrier();

    reg_write(reg_queue_notify, queue.index);

    const used: *volatile Used = @ptrFromInt(queue.base + page_size);

    while (used.idx == queue.last_used) {

        _ = try sys.wait(completion);
        acknowledge_device();
        _ = sys.acknowledge(cap.driver.interrupt) catch {};

    }

    queue.last_used = used.idx;
    acknowledge_device();
    _ = sys.acknowledge(cap.driver.interrupt) catch {};

}

fn session_for(badge: u64) ?*Session {

    return sessions.find(badge);

}

fn rate_code_for(rate: u64) ?u8 {

    return switch (rate) {

        5_512 => 0,
        8_000 => 1,
        11_025 => 2,
        16_000 => 3,
        22_050 => 4,
        32_000 => 5,
        44_100 => 6,
        48_000 => 7,
        64_000 => 8,
        88_200 => 9,
        96_000 => 10,
        176_400 => 11,
        192_000 => 12,
        else => null,

    };

}

fn acknowledge_device() void {

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
