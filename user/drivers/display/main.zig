// virtio-gpu display driver (07-userspace-ddd.md Section 12.2): an ordinary process holding its MMIO window, its Interrupt, and a DMA sub-grant.

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
const reg_config = 0x100;

const virtio_magic: u32 = 0x7472_6976;
const device_id_gpu: u32 = 16;

const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

const isr_used_ring: u32 = 1;
const isr_config: u32 = 2;

// virtio-gpu config space: events_read/events_clear signal EVENT_DISPLAY on a host resize.

const config_events_read = reg_config + 0;
const config_events_clear = reg_config + 4;

const event_display: u32 = 1;

// virtio-gpu control types.

const cmd_get_display_info: u32 = 0x0100;
const cmd_resource_create_2d: u32 = 0x0101;
const cmd_resource_unref: u32 = 0x0102;
const cmd_set_scanout: u32 = 0x0103;
const cmd_resource_flush: u32 = 0x0104;
const cmd_transfer_to_host_2d: u32 = 0x0105;
const cmd_resource_attach_backing: u32 = 0x0106;
const cmd_resource_detach_backing: u32 = 0x0107;
const cmd_update_cursor: u32 = 0x0300;
const cmd_move_cursor: u32 = 0x0301;

const resp_ok_nodata: u32 = 0x1100;
const resp_ok_display_info: u32 = 0x1101;

const format_b8g8r8a8: u32 = 1; // ARGB in a little-endian u32: the cursor plane
const format_b8g8r8x8: u32 = 2; // XRGB in a little-endian u32: the scanout (proto.display.format_xrgb)

const max_scanouts = 16;

const CtrlHeader = extern struct {

    kind: u32,
    flags: u32,

    fence_id: u64,
    ctx_id: u32,

    ring_idx: u8,
    padding: [3]u8,

};

const GpuRect = extern struct {

    x: u32,
    y: u32,

    width: u32,
    height: u32,

};

const DisplayOne = extern struct {

    rect: GpuRect,

    enabled: u32,
    flags: u32,

};

const ResourceCreate2d = extern struct {

    header: CtrlHeader,

    resource_id: u32,
    format: u32,

    width: u32,
    height: u32,

};

const ResourceUnref = extern struct {

    header: CtrlHeader,

    resource_id: u32,
    padding: u32,

};

const SetScanout = extern struct {

    header: CtrlHeader,
    rect: GpuRect,

    scanout_id: u32,
    resource_id: u32,

};

const ResourceFlush = extern struct {

    header: CtrlHeader,
    rect: GpuRect,

    resource_id: u32,
    padding: u32,

};

const TransferToHost2d = extern struct {

    header: CtrlHeader,
    rect: GpuRect,

    offset: u64,

    resource_id: u32,
    padding: u32,

};

const AttachBacking = extern struct {

    header: CtrlHeader,

    resource_id: u32,
    entry_count: u32,

    // One entry inline: every backing here is a single contiguous DMA Region.
    address: u64,
    length: u32,
    entry_padding: u32,

};

const DetachBacking = extern struct {

    header: CtrlHeader,

    resource_id: u32,
    padding: u32,

};

const CursorPos = extern struct {

    scanout_id: u32,

    x: u32,
    y: u32,

    padding: u32,

};

const UpdateCursor = extern struct {

    header: CtrlHeader,
    position: CursorPos,

    resource_id: u32,

    hot_x: u32,
    hot_y: u32,

    padding: u32,

};

// The split virtqueues: controlq 0 and cursorq 1, one request in flight at a time on each.

const queue_size = 8;

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

// Control DMA layout: two pages per queue (descriptors + avail, then used on its own page - the legacy
// alignment rule), one page split between command and response buffers, then the cursor image.

const page_size = 4096;

const controlq_offset = 0;
const cursorq_offset = 2 * page_size;
const command_offset = 4 * page_size;
const response_offset = command_offset + 2048;
const cursor_offset = 5 * page_size;

const cursor_bytes = proto.display.cursor_size * proto.display.cursor_size * 4;
const dma_pages = 5 + (cursor_bytes + page_size - 1) / page_size;

const avail_offset = queue_size * @sizeOf(Descriptor);
const used_offset = page_size;

const controlq = 0;
const cursorq = 1;

const cursor_resource: u32 = 1;

const notification_bit: u64 = 1;
const submit_sleep_ns: u64 = 1_000_000;
const control_submit_waits: usize = 250;
const cursor_submit_waits: usize = 50;

var regs: usize = 0;
var version: u32 = 0;

var dma_base: usize = 0;
var dma_physical: u64 = 0;

var last_used = [_]u16{ 0, 0 };

// The live mode and its scanout resource + backing.

var mode_width: u32 = 0;
var mode_height: u32 = 0;
var host_display_enabled = false;

var fb_region: Handle = 0;
var fb_base: usize = 0;
var fb_physical: u64 = 0;
var fb_resource: u32 = 0;
var next_resource: u32 = 2;

var cursor_ready = false;

// The compositor's mode-change Notification (attach_events).

var event_notification: ?Handle = null;
var event_bits: u64 = proto.display.mode_bit;

// virtio completion and config events share one bound notification; submit() sleeps on it instead of spinning.
var device_wake: Handle = 0;

// EVENT_DISPLAY can assert while submit() is waiting; note it here and apply after the in-flight command finishes.
var display_config_pending = false;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    const window = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);
    regs = window + @as(usize, @intCast(lib.start.word(3)));

    device_wake = try sys.create(.notification, 0, 0);
    try sys.bind(cap.driver.interrupt, device_wake, notification_bit);
    try sys.configure(cap.self_thread, .bound_notification, device_wake);

    const dma = try sys.create_dma(dma_pages * page_size, cap.driver.dma);
    dma_base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);
    dma_physical = dma.physical_base;

    const dma_bytes: [*]u8 = @ptrFromInt(dma_base);
    @memset(dma_bytes[0 .. dma_pages * page_size], 0);

    try init_device();
    try init_scanout();

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(cap.driver.endpoint, &in) catch continue;

        if (badge == cap.notification_wake) {

            handle_interrupt();

            continue;

        }

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

        drain_display_config();

    }

}

fn init_device() !void {

    if (reg_read(reg_magic) != virtio_magic) return error.NotFound;
    if (reg_read(reg_device_id) != device_id_gpu) return error.NotFound;

    version = reg_read(reg_version);

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
        reg_write(reg_driver_features, 1); // VIRTIO_F_VERSION_1 (feature bit 32)

        reg_write(reg_status, status_acknowledge | status_driver | status_features_ok);

        if (reg_read(reg_status) & status_features_ok == 0) return error.NotFound;

    } else {

        _ = reg_read(reg_device_features);
        reg_write(reg_driver_features, 0);
        reg_write(reg_guest_page_size, page_size);

    }

    try init_queue(controlq, controlq_offset);
    try init_queue(cursorq, cursorq_offset);

    reg_write(reg_status, reg_read(reg_status) | status_driver_ok);

}

fn init_queue(queue: u32, offset: usize) !void {

    reg_write(reg_queue_sel, queue);

    if (reg_read(reg_queue_num_max) < queue_size) return error.Invalid;

    reg_write(reg_queue_num, queue_size);

    const physical = dma_physical + offset;

    if (version == 2) {

        reg_write(reg_queue_desc_low, @truncate(physical));
        reg_write(reg_queue_desc_high, @truncate(physical >> 32));
        reg_write(reg_queue_driver_low, @truncate(physical + avail_offset));
        reg_write(reg_queue_driver_high, @truncate((physical + avail_offset) >> 32));
        reg_write(reg_queue_device_low, @truncate(physical + used_offset));
        reg_write(reg_queue_device_high, @truncate((physical + used_offset) >> 32));
        reg_write(reg_queue_ready, 1);

    } else {

        reg_write(reg_queue_align, page_size);
        reg_write(reg_queue_pfn, @truncate(physical / page_size));

    }

}

// Bring up (or rebuild, on resize) the scanout: query the host size, create a 2D resource, give it a fresh
// contiguous DMA backing, and point scanout 0 at it.

fn init_scanout() !void {

    // The host may not have wired a display surface yet (enabled=0). Build a scanout at the reported or
    // fallback size immediately; EVENT_DISPLAY will rewire and flush when the SDL surface appears.

    const size = try query_display();

    try build_framebuffer(size.width, size.height);

}

const Size = struct {

    width: u32,
    height: u32,

};

fn query_display() !Size {

    const header = CtrlHeader{

        .kind = cmd_get_display_info,
        .flags = 0,

        .fence_id = 0,
        .ctx_id = 0,

        .ring_idx = 0,
        .padding = .{ 0, 0, 0 },

    };

    const kind = try submit(controlq, @sizeOf(CtrlHeader), as_bytes(CtrlHeader, &header));

    if (kind != resp_ok_display_info) return error.Invalid;

    const info: [*]const u8 = @ptrFromInt(dma_base + response_offset + @sizeOf(CtrlHeader));
    const first: *const DisplayOne = @ptrCast(@alignCast(info));

    host_display_enabled = first.enabled != 0;

    if (host_display_enabled and first.rect.width != 0 and first.rect.height != 0) {

        return .{ .width = first.rect.width, .height = first.rect.height };

    }

    return .{ .width = 1280, .height = 800 };

}

fn build_framebuffer(width: u32, height: u32) !void {

    const bytes = @as(usize, width) * height * 4;
    const dma = try sys.create_dma((bytes + page_size - 1) & ~@as(usize, page_size - 1), cap.driver.dma);
    const base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);

    const resource = next_resource;
    next_resource += 1;

    try check_ok(try command(ResourceCreate2d, .{

        .header = header_of(cmd_resource_create_2d),

        .resource_id = resource,
        .format = format_b8g8r8x8,

        .width = width,
        .height = height,

    }));

    try check_ok(try command(AttachBacking, .{

        .header = header_of(cmd_resource_attach_backing),

        .resource_id = resource,
        .entry_count = 1,

        .address = dma.physical_base,
        .length = @intCast(bytes),
        .entry_padding = 0,

    }));

    try check_ok(try command(SetScanout, .{

        .header = header_of(cmd_set_scanout),
        .rect = .{ .x = 0, .y = 0, .width = width, .height = height },

        .scanout_id = 0,
        .resource_id = resource,

    }));

    // Retire the old scanout only after the new one is live.

    const old_resource = fb_resource;
    const old_region = fb_region;
    const old_base = fb_base;

    mode_width = width;
    mode_height = height;

    fb_region = dma.region;
    fb_base = base;
    fb_physical = dma.physical_base;
    fb_resource = resource;

    if (old_resource != 0) {

        _ = command(DetachBacking, .{

            .header = header_of(cmd_resource_detach_backing),

            .resource_id = old_resource,
            .padding = 0,

        }) catch 0;

        _ = command(ResourceUnref, .{

            .header = header_of(cmd_resource_unref),

            .resource_id = old_resource,
            .padding = 0,

        }) catch 0;

        sys.unmap(cap.self_space, old_base) catch {};
        sys.close(old_region) catch {};

    }

    // The compositor owns visible pixels; do not flush from here or we race ahead of its first composite.

}

fn rewire_scanout() !void {

    if (fb_resource == 0) return;

    try check_ok(try command(SetScanout, .{

        .header = header_of(cmd_set_scanout),
        .rect = .{ .x = 0, .y = 0, .width = mode_width, .height = mode_height },

        .scanout_id = 0,
        .resource_id = fb_resource,

    }));

}

fn dispatch(method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.display.mode_info => mode_info(out),
        proto.display.map_framebuffer => map_framebuffer(out),
        proto.display.flush => flush(in.data[1], in.data[2]),
        proto.display.attach_events => attach_events(in),
        proto.display.set_cursor => set_cursor(in),
        proto.display.move_cursor => move_cursor(in.data[1]),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.display.interface_id;
    out.data[2] = proto.display.version;

    return 0;

}

fn mode_info(out: *Message) i64 {

    out.data[1] = (@as(u64, mode_width) << 32) | mode_height;
    out.data[2] = @as(u64, mode_width) * 4;
    out.data[3] = proto.display.format_xrgb;

    return 0;

}

fn map_framebuffer(out: *Message) i64 {

    out.data[1] = @as(u64, mode_width) * mode_height * 4;
    out.handles[0] = .{ .handle = fb_region, .move = false };
    out.handle_count = 1;

    return 0;

}

fn flush(position: u64, extent: u64) i64 {

    const x: u32 = @intCast(@min(position >> 32, mode_width));
    const y: u32 = @intCast(@min(position & 0xffff_ffff, mode_height));
    const w: u32 = @intCast(@min(extent >> 32, mode_width - x));
    const h: u32 = @intCast(@min(extent & 0xffff_ffff, mode_height - y));

    if (w == 0 or h == 0) return 0;

    push_damage(x, y, w, h) catch return -7;

    return 0;

}

fn push_damage(x: u32, y: u32, w: u32, h: u32) !void {

    _ = .{ x, y, w, h };

    if (!host_display_enabled) return;

    barrier();

    // The scanout backing is guest RAM the compositor maps and writes; sync it to the host with transfer
    // then publish. Use the full resource each time so partial rectangles cannot drift after a resize.

    const rect = GpuRect{ .x = 0, .y = 0, .width = mode_width, .height = mode_height };

    try check_ok(try command(TransferToHost2d, .{

        .header = header_of(cmd_transfer_to_host_2d),
        .rect = rect,

        .offset = 0,

        .resource_id = fb_resource,
        .padding = 0,

    }));

    try check_ok(try command(ResourceFlush, .{

        .header = header_of(cmd_resource_flush),
        .rect = rect,

        .resource_id = fb_resource,
        .padding = 0,

    }));

}

fn attach_events(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    if (event_notification) |old| sys.close(old) catch {};

    event_notification = in.handles[0].handle;
    event_bits = if (in.data[1] != 0) in.data[1] else proto.display.mode_bit;

    if (event_notification) |notification| {

        sys.notify(notification, event_bits) catch {};

    }

    return 0;

}

// The cursor plane: copy the client's 64x64 ARGB image into DMA, upload it as a resource once, and let MOVE_CURSOR track the pointer without touching the framebuffer.

fn set_cursor(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    if (!host_display_enabled) {

        sys.close(in.handles[0].handle) catch {};

        return 0;

    }

    const image = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read) catch return -7;

    const source: [*]const u8 = @ptrFromInt(image);
    const destination: [*]u8 = @ptrFromInt(dma_base + cursor_offset);

    @memcpy(destination[0..cursor_bytes], source[0..cursor_bytes]);

    sys.unmap(cap.self_space, image) catch {};
    sys.close(in.handles[0].handle) catch {};

    if (!cursor_ready) {

        check_ok(command(ResourceCreate2d, .{

            .header = header_of(cmd_resource_create_2d),

            .resource_id = cursor_resource,
            .format = format_b8g8r8a8,

            .width = proto.display.cursor_size,
            .height = proto.display.cursor_size,

        }) catch return -7) catch return -7;

        check_ok(command(AttachBacking, .{

            .header = header_of(cmd_resource_attach_backing),

            .resource_id = cursor_resource,
            .entry_count = 1,

            .address = dma_physical + cursor_offset,
            .length = cursor_bytes,
            .entry_padding = 0,

        }) catch return -7) catch return -7;

        cursor_ready = true;

    }

    check_ok(command(TransferToHost2d, .{

        .header = header_of(cmd_transfer_to_host_2d),
        .rect = .{ .x = 0, .y = 0, .width = proto.display.cursor_size, .height = proto.display.cursor_size },

        .offset = 0,

        .resource_id = cursor_resource,
        .padding = 0,

    }) catch return -7) catch return -7;

    const hot_x: u32 = @intCast(in.data[1] >> 32);
    const hot_y: u32 = @truncate(in.data[1]);

    _ = command_on(cursorq, UpdateCursor, .{

        .header = header_of(cmd_update_cursor),
        .position = .{ .scanout_id = 0, .x = 0, .y = 0, .padding = 0 },

        .resource_id = cursor_resource,

        .hot_x = hot_x,
        .hot_y = hot_y,

        .padding = 0,

    }) catch return -7;

    return 0;

}

fn move_cursor(position: u64) i64 {

    if (!host_display_enabled) return 0;
    if (!cursor_ready) return -7;

    _ = command_on(cursorq, UpdateCursor, .{

        .header = header_of(cmd_move_cursor),
        .position = .{ .scanout_id = 0, .x = @intCast(position >> 32), .y = @truncate(position), .padding = 0 },

        .resource_id = cursor_resource,

        .hot_x = 0,
        .hot_y = 0,

        .padding = 0,

    }) catch return -7;

    return 0;

}

// A config interrupt is the host window resizing or the SDL surface appearing: clear the event, requery,
// rebuild or reattach scanout, wake the compositor, and push the backing to the host.

fn handle_interrupt() void {

    _ = sys.acknowledge(cap.driver.interrupt) catch {};

    const status = reg_read(reg_interrupt_status);

    if (status != 0) reg_write(reg_interrupt_ack, status);

    note_display_config_event();

    if (!display_config_pending) return;

    display_config_pending = false;

    _ = apply_display_resize();

}

fn note_display_config_event() void {

    if (reg_read(config_events_read) & event_display != 0) display_config_pending = true;

}

fn drain_display_config() void {

    if (!display_config_pending) return;

    display_config_pending = false;

    _ = apply_display_resize();

}

fn apply_display_resize() bool {

    const events = reg_read(config_events_read);

    if (events & event_display == 0) return false;

    const size = query_display() catch return false;

    if (!host_display_enabled) {

        display_config_pending = true;

        return false;

    }

    reg_write(config_events_clear, event_display);

    if (size.width == mode_width and size.height == mode_height) {

        if (fb_resource == 0) return false;

        rewire_scanout() catch {};
        push_damage(0, 0, mode_width, mode_height) catch {};

    } else {

        build_framebuffer(size.width, size.height) catch return false;

    }

    if (event_notification) |notification| {

        sys.notify(notification, event_bits) catch {};

    }

    return true;

}

// Synchronous command submission: one out descriptor (the command), one in descriptor (the response), then poll the used ring. Config events raised while polling are handled on the next endpoint wake.

fn command(comptime T: type, payload: T) !u32 {

    return command_on(controlq, T, payload);

}

fn command_on(queue: u32, comptime T: type, payload: T) !u32 {

    const staged = payload;

    return submit(queue, @sizeOf(T), as_bytes(T, &staged));

}

fn as_bytes(comptime T: type, payload: *const T) [*]const u8 {

    return @ptrCast(payload);

}

fn submit(queue: u32, length: usize, bytes: [*]const u8) !u32 {

    const queue_offset: usize = if (queue == controlq) controlq_offset else cursorq_offset;
    const queue_base = dma_base + queue_offset;

    const buffer: [*]u8 = @ptrFromInt(dma_base + command_offset);
    @memcpy(buffer[0..length], bytes[0..length]);

    const response: *volatile CtrlHeader = @ptrFromInt(dma_base + response_offset);
    response.kind = 0;

    const descriptors: [*]volatile Descriptor = @ptrFromInt(queue_base);

    descriptors[0] = .{ .addr = dma_physical + command_offset, .len = @intCast(length), .flags = descriptor_next, .next = 1 };
    descriptors[1] = .{ .addr = dma_physical + response_offset, .len = 2048, .flags = descriptor_write, .next = 0 };

    const avail: *volatile Avail = @ptrFromInt(queue_base + avail_offset);

    avail.ring[avail.idx % queue_size] = 0;

    barrier();

    avail.idx +%= 1;

    barrier();

    reg_write(reg_queue_notify, queue);

    const used: *volatile Used = @ptrFromInt(queue_base + used_offset);

    const wait_limit = if (queue == cursorq) cursor_submit_waits else control_submit_waits;
    var waits: usize = 0;

    while (true) {

        barrier();

        if (used.idx != last_used[queue]) {

            last_used[queue] = used.idx;
            acknowledge_used();

            return response.kind;

        }

        acknowledge_used();

        note_display_config_event();

        if (waits >= wait_limit) return error.Gone;

        sys.sleep(submit_sleep_ns);

        waits += 1;

    }

}

fn acknowledge_used() void {

    const status = reg_read(reg_interrupt_status);

    if (status != 0) reg_write(reg_interrupt_ack, status);

}

fn check_ok(kind: u32) !void {

    if (kind != resp_ok_nodata) return error.Invalid;

}

fn header_of(kind: u32) CtrlHeader {

    return .{

        .kind = kind,
        .flags = 0,

        .fence_id = 0,
        .ctx_id = 0,

        .ring_idx = 0,
        .padding = .{ 0, 0, 0 },

    };

}

fn barrier() void {

    if (comptime @import("builtin").cpu.arch == .x86_64) {

        asm volatile ("mfence" ::: .{ .memory = true });

    } else {

        asm volatile ("dsb sy" ::: .{ .memory = true });

    }

}

fn reg_read(offset: usize) u32 {

    const register: *volatile u32 = @ptrFromInt(regs + offset);

    return register.*;

}

fn reg_write(offset: usize, value: u32) void {

    const register: *volatile u32 = @ptrFromInt(regs + offset);

    register.* = value;

}
