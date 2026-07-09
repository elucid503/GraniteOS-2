// Input server (07-userspace-ddd.md Section 12.4): merges every virtio-input transport (QEMU's keyboard and
// tablet) into one normalized event stream. The per-device drivers live in-process - each device is a grant
// pair (MMIO window + Interrupt) with its own eventq - and delivery to the client rides the shared event ring
// + Notification of the Input interface (Section 10.8), so everyone blocks instead of polling. Pointer
// positions are normalized to proto.input.pointer_range; the compositor owns scaling, focus, and routing.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
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

// virtio-input config space: a select/subsel window over device metadata.

const config_select = 0x100;
const config_subsel = 0x101;
const config_size = 0x102;
const config_payload = 0x108;

const select_abs_info: u8 = 0x12;

const virtio_magic: u32 = 0x7472_6976;
const device_id_input: u32 = 18;

const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

// Linux evdev event types and codes, as virtio-input reports them.

const ev_syn: u16 = 0;
const ev_key: u16 = 1;
const ev_rel: u16 = 2;
const ev_abs: u16 = 3;

const rel_x: u16 = 0;
const rel_y: u16 = 1;
const rel_wheel: u16 = 8;

const abs_x: u16 = 0;
const abs_y: u16 = 1;

const btn_left: u16 = 0x110;
const btn_right: u16 = 0x111;
const btn_middle: u16 = 0x112;

// The split eventq: 32 device-writable 8-byte buffers, reposted as they drain.

const queue_size = 32;

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

const InputEvent = extern struct {

    kind: u16,
    code: u16,

    value: u32,

};

// Per-device DMA layout: eventq descriptors + avail, eventq used (the legacy alignment rule), statusq
// descriptors + avail, statusq used, then the event buffers.

const page_size = 4096;

const eventq_offset = 0;
const statusq_offset = 2 * page_size;
const buffers_offset = 4 * page_size;

const dma_pages = 5;

const avail_offset = queue_size * @sizeOf(Descriptor);
const used_offset = page_size;

const max_devices = 4;

const Device = struct {

    regs: usize = 0,

    interrupt: Handle = 0,

    dma_base: usize = 0,
    dma_physical: u64 = 0,

    last_used: u16 = 0,

    // Absolute-axis scaling, from the device's abs_info config.
    abs_min: [2]i64 = .{ 0, 0 },
    abs_span: [2]i64 = .{ 32767, 32767 },

    // Coalesced pointer state, emitted once per EV_SYN.
    pointer: [2]i32 = .{ -1, -1 },
    pointer_moved: bool = false,

};

var devices: [max_devices]Device = [_]Device{.{}} ** max_devices;
var device_count: usize = 0;
var dma_authority: Handle = 0;

// The one attached client (the compositor): its event ring and wake Notification.

var client_ring: ?events.Ring = null;
var client_base: usize = 0;
var client_notification: Handle = 0;
var client_bits: u64 = proto.input.ring_bit;
var client_pushed = false;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    const count: usize = @intCast(lib.start.word(3));
    const offsets = lib.start.word(4);

    if (count == 0 or count > max_devices) return error.Invalid;

    dma_authority = cap.input.dma(count);

    const wake = try sys.create(.notification, 0, 0);

    for (0..count) |index| {

        const window: Handle = @intCast(cap.input.devices + index);
        const interrupt: Handle = @intCast(cap.input.devices + count + index);
        const in_page: usize = @intCast((offsets >> @intCast(16 * index)) & 0xffff);

        const base = try sys.map(cap.self_space, window, 0, sys.read | sys.write);

        devices[device_count] = .{

            .regs = base + in_page,
            .interrupt = interrupt,

        };

        try init_device(&devices[device_count]);
        try sys.bind(interrupt, wake, @as(u64, 1) << @intCast(device_count));

        device_count += 1;

    }

    try sys.configure(cap.self_thread, .bound_notification, wake);

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(cap.server.endpoint, &in) catch continue;

        if (badge == cap.notification_wake) {

            drain_devices();

            continue;

        }

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

        // Requests and interrupts share the endpoint; sweep for events the wake may have raced past.

        drain_devices();

    }

}

fn init_device(device: *Device) !void {

    if (reg_read(device, reg_magic) != virtio_magic) return error.NotFound;
    if (reg_read(device, reg_device_id) != device_id_input) return error.NotFound;

    const version = reg_read(device, reg_version);

    if (version != 1 and version != 2) return error.NotFound;

    reg_write(device, reg_status, 0); // reset
    reg_write(device, reg_status, status_acknowledge);
    reg_write(device, reg_status, status_acknowledge | status_driver);

    if (version == 2) {

        reg_write(device, reg_device_features_sel, 0);
        _ = reg_read(device, reg_device_features);
        reg_write(device, reg_driver_features_sel, 0);
        reg_write(device, reg_driver_features, 0);

        reg_write(device, reg_device_features_sel, 1);
        _ = reg_read(device, reg_device_features);
        reg_write(device, reg_driver_features_sel, 1);
        reg_write(device, reg_driver_features, 1); // VIRTIO_F_VERSION_1

        reg_write(device, reg_status, status_acknowledge | status_driver | status_features_ok);

        if (reg_read(device, reg_status) & status_features_ok == 0) return error.NotFound;

    } else {

        _ = reg_read(device, reg_device_features);
        reg_write(device, reg_driver_features, 0);
        reg_write(device, reg_guest_page_size, page_size);

    }

    const dma = try sys.create_dma(dma_pages * page_size, dma_authority);

    device.dma_base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);
    device.dma_physical = dma.physical_base;

    const bytes: [*]u8 = @ptrFromInt(device.dma_base);
    @memset(bytes[0 .. dma_pages * page_size], 0);

    try init_queue(device, 0, eventq_offset, version);
    try init_queue(device, 1, statusq_offset, version);

    // Post every event buffer before the device goes live.

    const descriptors: [*]volatile Descriptor = @ptrFromInt(device.dma_base + eventq_offset);
    const avail: *volatile Avail = @ptrFromInt(device.dma_base + eventq_offset + avail_offset);

    for (0..queue_size) |slot| {

        descriptors[slot] = .{

            .addr = device.dma_physical + buffers_offset + slot * @sizeOf(InputEvent),
            .len = @sizeOf(InputEvent),

            .flags = descriptor_write,
            .next = 0,

        };

        avail.ring[slot] = @intCast(slot);

    }

    barrier();

    avail.idx = queue_size;

    barrier();

    reg_write(device, reg_status, reg_read(device, reg_status) | status_driver_ok);
    reg_write(device, reg_queue_notify, 0);

    read_abs_info(device);

}

fn init_queue(device: *Device, queue: u32, offset: usize, version: u32) !void {

    reg_write(device, reg_queue_sel, queue);

    if (reg_read(device, reg_queue_num_max) < queue_size) return error.Invalid;

    reg_write(device, reg_queue_num, queue_size);

    const physical = device.dma_physical + offset;

    if (version == 2) {

        reg_write(device, reg_queue_desc_low, @truncate(physical));
        reg_write(device, reg_queue_desc_high, @truncate(physical >> 32));
        reg_write(device, reg_queue_driver_low, @truncate(physical + avail_offset));
        reg_write(device, reg_queue_driver_high, @truncate((physical + avail_offset) >> 32));
        reg_write(device, reg_queue_device_low, @truncate(physical + used_offset));
        reg_write(device, reg_queue_device_high, @truncate((physical + used_offset) >> 32));
        reg_write(device, reg_queue_ready, 1);

    } else {

        reg_write(device, reg_queue_align, page_size);
        reg_write(device, reg_queue_pfn, @truncate(physical / page_size));

    }

}

// Query the absolute-axis ranges (the tablet reports 0..32767); relative devices leave the defaults.

fn read_abs_info(device: *Device) void {

    for (0..2) |axis| {

        byte_write(device, config_select, select_abs_info);
        byte_write(device, config_subsel, @intCast(axis));

        if (byte_read(device, config_size) < 8) continue;

        const min: i64 = @as(i32, @bitCast(payload_read(device, 0)));
        const max: i64 = @as(i32, @bitCast(payload_read(device, 4)));

        if (max > min) {

            device.abs_min[axis] = min;
            device.abs_span[axis] = max - min;

        }

    }

    byte_write(device, config_select, 0);

}

fn dispatch(method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.input.attach => attach(in),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.input.interface_id;
    out.data[2] = proto.input.version;

    return 0;

}

fn attach(in: *const Message) i64 {

    if (in.handle_count < 2) return -7;

    const base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;

    if (client_base != 0) sys.unmap(cap.self_space, client_base) catch {};
    if (client_notification != 0) sys.close(client_notification) catch {};

    client_ring = events.Ring.init(base, @intCast(in.data[1]));
    client_base = base;
    client_notification = in.handles[1].handle;
    client_bits = if (in.data[2] != 0) in.data[2] else proto.input.ring_bit;

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn drain_devices() void {

    client_pushed = false;

    for (devices[0..device_count]) |*device| {

        drain(device);

    }

    if (client_pushed and client_notification != 0) {

        sys.notify(client_notification, client_bits) catch {};

    }

}

fn drain(device: *Device) void {

    _ = sys.acknowledge(device.interrupt) catch {};

    const status = reg_read(device, reg_interrupt_status);

    if (status != 0) reg_write(device, reg_interrupt_ack, status);

    const used: *volatile Used = @ptrFromInt(device.dma_base + eventq_offset + used_offset);
    const avail: *volatile Avail = @ptrFromInt(device.dma_base + eventq_offset + avail_offset);
    const buffers: [*]volatile InputEvent = @ptrFromInt(device.dma_base + buffers_offset);

    var reposted = false;

    while (true) {

        barrier();

        if (used.idx == device.last_used) break;

        const element = used.ring[device.last_used % queue_size];

        device.last_used +%= 1;

        const raw = buffers[element.id];

        translate(device, .{ .kind = raw.kind, .code = raw.code, .value = raw.value });

        // Hand the buffer straight back to the device.

        avail.ring[avail.idx % queue_size] = @intCast(element.id);

        barrier();

        avail.idx +%= 1;

        reposted = true;

    }

    if (reposted) reg_write(device, reg_queue_notify, 0);

}

fn translate(device: *Device, raw: InputEvent) void {

    switch (raw.kind) {

        ev_syn => {

            if (device.pointer_moved) {

                device.pointer_moved = false;

                push(.{

                    .kind = events.kind_pointer_move,
                    .code = 0,
                    .window = 0,

                    .x = device.pointer[0],
                    .y = device.pointer[1],

                    .value = 0,

                });

            }

        },

        ev_key => {

            const value: i64 = @intCast(raw.value);

            if (raw.code >= btn_left and raw.code <= btn_middle) {

                const button: u16 = switch (raw.code) {

                    btn_left => events.button_left,
                    btn_right => events.button_right,

                    else => events.button_middle,

                };

                push(.{

                    .kind = if (raw.value != 0) events.kind_button_down else events.kind_button_up,
                    .code = button,
                    .window = 0,

                    .x = device.pointer[0],
                    .y = device.pointer[1],

                    .value = value,

                });

                return;

            }

            push(.{

                .kind = if (raw.value != 0) events.kind_key_down else events.kind_key_up,
                .code = raw.code,
                .window = 0,

                .x = 0,
                .y = 0,

                .value = value,

            });

        },

        ev_abs => {

            if (raw.code == abs_x or raw.code == abs_y) {

                const axis: usize = raw.code;
                const range: i64 = @intCast(proto.input.pointer_range);
                const value: i64 = @as(i32, @bitCast(raw.value));

                const scaled = @divTrunc((value - device.abs_min[axis]) * range, device.abs_span[axis]);

                device.pointer[axis] = @intCast(@max(0, @min(range, scaled)));
                device.pointer_moved = true;

            }

        },

        ev_rel => {

            if (raw.code == rel_wheel) {

                push(.{

                    .kind = events.kind_scroll,
                    .code = 0,
                    .window = 0,

                    .x = device.pointer[0],
                    .y = device.pointer[1],

                    .value = @as(i32, @bitCast(raw.value)),

                });

            }

        },

        else => {},

    }

}

fn push(event: events.Event) void {

    const ring = client_ring orelse return;

    if (ring.push(event)) client_pushed = true;

}

fn byte_read(device: *Device, offset: usize) u8 {

    const register: *volatile u8 = @ptrFromInt(device.regs + offset);

    return register.*;

}

fn byte_write(device: *Device, offset: usize, value: u8) void {

    const register: *volatile u8 = @ptrFromInt(device.regs + offset);

    register.* = value;

}

fn payload_read(device: *Device, offset: usize) u32 {

    const register: *volatile u32 = @ptrFromInt(device.regs + config_payload + offset);

    return register.*;

}

fn barrier() void {

    if (comptime @import("builtin").cpu.arch == .x86_64) {

        asm volatile ("mfence" ::: .{ .memory = true });

    } else {

        asm volatile ("dsb sy" ::: .{ .memory = true });

    }

}

fn reg_read(device: *Device, offset: usize) u32 {

    const register: *volatile u32 = @ptrFromInt(device.regs + offset);

    return register.*;

}

fn reg_write(device: *Device, offset: usize, value: u32) void {

    const register: *volatile u32 = @ptrFromInt(device.regs + offset);

    register.* = value;

}
