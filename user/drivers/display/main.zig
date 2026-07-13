// ramfb display driver: fw_cfg `etc/ramfb` points QEMU at a dumb linear framebuffer in guest RAM.
// QEMU page-dirty tracking replaces virtio-gpu transfer/flush; trailing becomes impossible.

const lib = @import("lib");

const cap = lib.cap;
const fw_cfg = lib.fw_cfg;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

const page_size = 4096;

// Fixed mode shared with the browser Wasm profile (GraniteOS web GOS2_SCREEN).
const mode_width: u32 = 1024;
const mode_height: u32 = 640;
const mode_stride: u32 = mode_width * 4;
const fb_bytes: usize = @as(usize, mode_height) * mode_stride;

const cursor_side = proto.display.cursor_size;
const cursor_pixels = cursor_side * cursor_side;

var fw: fw_cfg.FwCfg = undefined;

var fb_region: Handle = 0;
var fb_base: usize = 0;

var event_notification: ?Handle = null;
var event_bits: u64 = proto.display.mode_bit;

// Software cursor: ramfb has no hardware plane; redraw after every compositor flush.
var cursor_image: [cursor_pixels]u32 = [_]u32{0} ** cursor_pixels;
var cursor_under: [cursor_pixels]u32 = [_]u32{0} ** cursor_pixels;
var cursor_ready = false;
var cursor_saved = false;
var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var hot_x: i32 = 0;
var hot_y: i32 = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch |err| {

        lib.log.fmt("Display: ramfb driver failed: {s}\n", .{@errorName(err)});

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    const window = try sys.map(cap.self_space, cap.display_driver.device, 0, sys.read | sys.write);
    const regs = window + @as(usize, @intCast(lib.start.word(3)));

    const scratch = try sys.create_dma(page_size, cap.display_driver.dma);
    const scratch_va = try sys.map(cap.self_space, scratch.region, 0, sys.read | sys.write);

    @memset(@as([*]u8, @ptrFromInt(scratch_va))[0..page_size], 0);

    fw = fw_cfg.FwCfg.init(regs, scratch_va, scratch.physical_base);

    if (!fw.present()) return error.NotFound;

    const selector = fw.find(fw_cfg.ramfb_name) orelse return error.NotFound;

    try build_framebuffer(selector);

    lib.log.line("Display: ramfb driver ... Loaded\n");

    var in = Message.zeroed;

    while (true) {

        _ = sys.receive(cap.display_driver.endpoint, &in) catch continue;

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

    }

}

fn build_framebuffer(selector: u16) !void {

    const dma = try sys.create_dma((fb_bytes + page_size - 1) & ~@as(usize, page_size - 1), cap.display_driver.dma);
    const base = try sys.map(cap.self_space, dma.region, 0, sys.read | sys.write);

    @memset(@as([*]u8, @ptrFromInt(base))[0..fb_bytes], 0);

    try fw_cfg.writeRamfbCfg(
        &fw,
        selector,
        dma.physical_base,
        fw_cfg.fourcc_xrgb8888,
        mode_width,
        mode_height,
        mode_stride,
    );

    fb_region = dma.region;
    fb_base = base;

}

fn dispatch(method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.display.mode_info => mode_info(out),
        proto.display.map_framebuffer => map_framebuffer(out),
        proto.display.flush => flush(),
        proto.display.attach_events => attach_events(in),
        proto.display.set_cursor => set_cursor(in),
        proto.display.move_cursor => move_cursor(in.data[1]),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.display.interface_id;
    out.data[2] = proto.display.version;

    return 0;

}

fn mode_info(out: *Message) i64 {

    out.data[1] = (@as(u64, mode_width) << 32) | mode_height;
    out.data[2] = mode_stride;
    out.data[3] = proto.display.format_xrgb;

    return 0;

}

fn map_framebuffer(out: *Message) i64 {

    out.data[1] = fb_bytes;
    out.handles[0] = .{ .handle = fb_region, .move = false };
    out.handle_count = 1;

    return 0;

}

// QEMU watches FB pages directly; flush only restores the soft cursor after compositor writes.
fn flush() i64 {

    if (!cursor_ready) return 0;

    // Compositor already replaced pixels under the cursor; resnap and redraw.
    cursor_saved = false;
    save_under();
    blit_cursor();

    return 0;

}

fn attach_events(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    if (event_notification) |old| sys.close(old) catch {};

    event_notification = in.handles[0].handle;
    event_bits = if (in.data[1] != 0) in.data[1] else proto.display.mode_bit;

    // Fixed ramfb mode: signal once so the compositor proceeds like a settled mode.
    if (event_notification) |notification| {

        sys.notify(notification, event_bits) catch {};

    }

    return 0;

}

fn set_cursor(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    const image = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read) catch return -7;
    const source: [*]const u32 = @ptrFromInt(image);

    if (cursor_saved) restore_under();

    @memcpy(cursor_image[0..cursor_pixels], source[0..cursor_pixels]);

    hot_x = @intCast(in.data[1] >> 32);
    hot_y = @intCast(in.data[1] & 0xffff_ffff);
    cursor_ready = true;

    sys.unmap(cap.self_space, image) catch {};
    sys.close(in.handles[0].handle) catch {};

    save_under();
    blit_cursor();

    return 0;

}

fn move_cursor(position: u64) i64 {

    if (!cursor_ready) return 0;

    if (cursor_saved) restore_under();

    cursor_x = @intCast(position >> 32);
    cursor_y = @intCast(position & 0xffff_ffff);

    save_under();
    blit_cursor();

    return 0;

}

fn cursor_origin() struct { x: i32, y: i32 } {

    return .{ .x = cursor_x - hot_x, .y = cursor_y - hot_y };

}

fn save_under() void {

    const origin = cursor_origin();
    const pixels: [*]u32 = @ptrFromInt(fb_base);

    var row: i32 = 0;

    while (row < cursor_side) : (row += 1) {

        var col: i32 = 0;

        while (col < cursor_side) : (col += 1) {

            const x = origin.x + col;
            const y = origin.y + row;
            const slot = @as(usize, @intCast(row)) * cursor_side + @as(usize, @intCast(col));

            if (x < 0 or y < 0 or x >= mode_width or y >= mode_height) {

                cursor_under[slot] = 0;
                continue;

            }

            cursor_under[slot] = pixels[@as(usize, @intCast(y)) * mode_width + @as(usize, @intCast(x))];

        }

    }

    cursor_saved = true;

}

fn restore_under() void {

    if (!cursor_saved) return;

    const origin = cursor_origin();
    const pixels: [*]u32 = @ptrFromInt(fb_base);

    var row: i32 = 0;

    while (row < cursor_side) : (row += 1) {

        var col: i32 = 0;

        while (col < cursor_side) : (col += 1) {

            const x = origin.x + col;
            const y = origin.y + row;

            if (x < 0 or y < 0 or x >= mode_width or y >= mode_height) continue;

            const slot = @as(usize, @intCast(row)) * cursor_side + @as(usize, @intCast(col));

            pixels[@as(usize, @intCast(y)) * mode_width + @as(usize, @intCast(x))] = cursor_under[slot];

        }

    }

    cursor_saved = false;

}

fn blit_cursor() void {

    const origin = cursor_origin();
    const pixels: [*]u32 = @ptrFromInt(fb_base);

    var row: i32 = 0;

    while (row < cursor_side) : (row += 1) {

        var col: i32 = 0;

        while (col < cursor_side) : (col += 1) {

            const x = origin.x + col;
            const y = origin.y + row;

            if (x < 0 or y < 0 or x >= mode_width or y >= mode_height) continue;

            const slot = @as(usize, @intCast(row)) * cursor_side + @as(usize, @intCast(col));
            const src = cursor_image[slot];
            const alpha: u8 = @truncate(src >> 24);

            if (alpha == 0) continue;

            const dst_i = @as(usize, @intCast(y)) * mode_width + @as(usize, @intCast(x));

            if (alpha == 255) {

                pixels[dst_i] = src & 0x00ff_ffff;
                continue;

            }

            pixels[dst_i] = mix(pixels[dst_i], src, alpha);

        }

    }

}

fn mix(dst: u32, src: u32, alpha: u8) u32 {

    const inv: u32 = 255 - alpha;

    const db: u32 = dst & 0xff;
    const dg: u32 = (dst >> 8) & 0xff;
    const dr: u32 = (dst >> 16) & 0xff;

    const sb: u32 = src & 0xff;
    const sg: u32 = (src >> 8) & 0xff;
    const sr: u32 = (src >> 16) & 0xff;

    const b = (sb * alpha + db * inv + 127) / 255;
    const g = (sg * alpha + dg * inv + 127) / 255;
    const r = (sr * alpha + dr * inv + 127) / 255;

    return (r << 16) | (g << 8) | b;

}
