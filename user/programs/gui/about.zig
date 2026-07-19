// About screen; desktop context menu only, not in the launcher.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;
const sysinfo = lib.sysinfo;
const ui = lib.ui;

comptime {

    _ = lib.start;

}

const pad: i32 = 20;
const key_w: i32 = 56;
const cell_w: i32 = 190;
const uptime_tick_ms = 1000;
const uptime_id: u32 = 1;

const worker_stack_pages = 8;
const page_size = 4096;

const features = [_][]const u8{

    "- Capability-based microkernel",
    "- User-space drivers and servers",
    "- MLFQ scheduler and Strata filesystem",
    "- FLINT, MARBLE, and a desktop user interface",

};

const SystemField = struct {

    key: []const u8,
    value: []const u8,

};

var font: lib.draw.text.Face = undefined;
var page: ui.Page = .{ .font = &font };

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var client: ?lib.fs.Client = null;

var ready: cap.Handle = 0;
var tick: u32 = 0;
var running: u32 = 1;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try connection.create_window(440, 320, 0, "About GraniteOS 2");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

    } else |_| {}

    paint(true);
    try start_worker();

    while (true) {

        var repaint_all = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    window.destroy();
                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    repaint_all = true;

                },

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    repaint_all = true;

                },

                events.kind_pointer_move => lib.cursor.set(&connection, .pointer),

                else => {},

            }

        }

        const update_uptime = @atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0;

        if (repaint_all or update_uptime) paint(repaint_all);

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

    }

}

fn paint(repaint_all: bool) void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    var cpu_buf: [32]u8 = undefined;
    var mem_buf: [32]u8 = undefined;
    var disk_buf: [32]u8 = undefined;
    var uptime_buf: [32]u8 = undefined;

    const fields = [_]SystemField{

        .{ .key = "Host", .value = "QEMU virt" },
        .{ .key = "Arch", .value = "aarch64" },
        .{ .key = "CPU", .value = format_cpu(&cpu_buf) },
        .{ .key = "Memory", .value = format_memory(&mem_buf) },
        .{ .key = "Disk", .value = format_disk(&disk_buf) },
        .{ .key = "Uptime", .value = format_uptime(&uptime_buf) },

    };

    page.begin(width, height, .{

        .direction = .column,
        .width = .{ .px = width },
        .height = .{ .px = height },
        .padding = ui.Edge.all(pad),
        .gap = 14,

    });

    _ = page.label(ui.Page.root, "GraniteOS 2", .{

        .size = 26,
        .color = ui.theme.text,

    });

    _ = page.label(ui.Page.root, "A from-scratch microkernel OS built in Zig.", .{

        .size = 13,
        .color = ui.theme.text_dim,

    });

    const feature_block = page.box(ui.Page.root, .{

        .direction = .column,
        .gap = 10,

    });

    _ = page.label(feature_block, "Features", .{

        .size = 14,
        .color = ui.theme.text,

    });

    const feature_list = page.box(feature_block, .{

        .direction = .column,
        .gap = 3,

    });

    for (features) |line| {

        _ = page.label(feature_list, line, .{

            .size = 12,
            .color = ui.theme.text_dim,

        });

    }

    const info_block = page.box(ui.Page.root, .{

        .direction = .column,
        .gap = 10,

    });

    _ = page.label(info_block, "System", .{

        .size = 14,
        .color = ui.theme.text,

    });

    const grid = page.box(info_block, .{

        .direction = .column,
        .gap = 4,

    });

    var index: usize = 0;

    while (index < fields.len) : (index += 2) {

        const row = page.box(grid, .{

            .direction = .row,
            .gap = 16,

        });

        info_cell(row, fields[index].key, fields[index].value, if (index == 5) uptime_id else 0);

        if (index + 1 < fields.len) {

            info_cell(row, fields[index + 1].key, fields[index + 1].value, if (index + 1 == 5) uptime_id else 0);

        }

    }

    page.end();

    if (repaint_all) {

        page.mark_all_dirty();

    } else if (page.rect_of(uptime_id)) |rect| {

        page.mark_dirty(rect);

    }

    const damage = page.damage.intersect(surface.bounds());

    if (damage.is_empty()) return;

    const clipped = surface.clipped(damage);

    paint_background(&clipped);
    page.present_dirty(&window) catch {};

}

fn paint_background(surface: *const gfx.Surface) void {

    surface.fill(ui.theme.window_bg);

}

fn info_cell(parent: i16, key: []const u8, value: []const u8, id: u32) void {

    const cell = page.box(parent, .{

        .id = id,
        .direction = .row,
        .width = .{ .px = cell_w },
        .gap = 8,
        .align_cross = .center,

    });

    _ = page.label(cell, key, .{

        .width = .{ .px = key_w },
        .size = 12,
        .color = ui.theme.accent,

    });

    _ = page.label(cell, value, .{

        .size = 12,
        .color = ui.theme.text,

    });

}

fn format_cpu(buffer: []u8) []const u8 {

    const snapshot = sysinfo.read(sysinfo.CpuSnapshot, .cpu) catch return "unavailable";

    return std.fmt.bufPrint(buffer, "{d} cores", .{snapshot.core_count}) catch "unavailable";

}

fn format_memory(buffer: []u8) []const u8 {

    const snapshot = sysinfo.read(sysinfo.MemorySnapshot, .memory) catch return "unavailable";

    const total = snapshot.total_frames * @as(u64, snapshot.page_size);

    return std.fmt.bufPrint(buffer, "{d} MiB", .{total / (1024 * 1024)}) catch "unavailable";

}

fn format_disk(buffer: []u8) []const u8 {

    const handle = if (client) |*c| c else return "unavailable";
    const info = handle.info() catch return "unavailable";

    const total = info.block_count * info.block_size;

    return std.fmt.bufPrint(buffer, "{d} MiB", .{total / (1024 * 1024)}) catch "unavailable";

}

fn format_uptime(buffer: []u8) []const u8 {

    const total_s = lib.time.now_ms() / 1000;
    const seconds = total_s % 60;
    const total_m = total_s / 60;
    const minutes = total_m % 60;
    const hours = total_m / 60;

    if (hours > 0) {

        return std.fmt.bufPrint(buffer, "{d}h {d}m {d}s", .{ hours, minutes, seconds }) catch "unavailable";

    }

    if (minutes > 0) {

        return std.fmt.bufPrint(buffer, "{d}m {d}s", .{ minutes, seconds }) catch "unavailable";

    }

    return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch "unavailable";

}

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        lib.time.sleep_ms(uptime_tick_ms);

        if (@atomicLoad(u32, &running, .acquire) == 0) break;

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, lib.proto.window.ring_bit) catch {};

    }

    while (true) lib.time.sleep_ms(1000);

}
