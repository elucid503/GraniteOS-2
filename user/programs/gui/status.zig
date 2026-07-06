// Status: a live system monitor. A worker thread samples the kernel inspect snapshots (scheduler, processes, CPU)
// and the filesystem's disk usage once a second, appending to per-metric history rings; the main thread draws the
// selected tab - a realtime line chart plus a current readout. Because the samples are timed off the EL0 counter
// (lib.time), the graphs advance in real seconds without any timer interrupt.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const sys = lib.sys;
const sysinfo = lib.sysinfo;
const ui = lib.ui;

const Rect = gfx.Rect;

comptime {

    _ = lib.start;

}

const tab_height: i32 = 42;
const sample_interval_ms = 1000;
const history_span = 64;

const Tab = enum(usize) {

    scheduler = 0,
    processes,
    cpu,
    disk,

};

const tabs = [_]struct { label: []const u8, icon: []const u8 }{

    .{ .label = "Scheduler", .icon = lib.icons.apps },
    .{ .label = "Processes", .icon = lib.icons.chart },
    .{ .label = "CPU", .icon = lib.icons.cpu },
    .{ .label = "Disk", .icon = lib.icons.disk },

};

const History = struct {

    samples: [history_span]u32 = [_]u32{0} ** history_span,
    len: usize = 0,

    fn push(self: *History, value: u32) void {

        if (self.len < history_span) {

            self.samples[self.len] = value;
            self.len += 1;

            return;

        }

        var index: usize = 1;

        while (index < history_span) : (index += 1) {

            self.samples[index - 1] = self.samples[index];

        }

        self.samples[history_span - 1] = value;

    }

    fn peak(self: *const History) u32 {

        var max: u32 = 1;

        for (self.samples[0..self.len]) |value| {

            if (value > max) max = value;

        }

        return max;

    }

};

var font: lib.ttf.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var active: Tab = .scheduler;

// Shared between the sampler thread and the paint loop.

var lock: ipc.Lock = .{};

var scheduler_snapshot: sysinfo.SchedulerSnapshot = undefined;
var process_snapshot: sysinfo.ProcessSnapshot = undefined;
var cpu_snapshot: sysinfo.CpuSnapshot = undefined;
var have_scheduler = false;
var have_processes = false;
var have_cpu = false;

var disk_info: lib.proto.filesystem.Info = undefined;
var have_disk = false;
var client: ?lib.fs.Client = null;

var runqueue_history = History{};
var thread_history = History{};
var busy_history = History{};
var disk_history = History{};

var ready: cap.Handle = 0;
var tick: u32 = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window = try connection.create_window(720, 460, 0, "Status");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

    } else |_| {}

    sample();
    paint();

    try start_sampler();

    while (true) {

        _ = sys.wait(ready) catch {};

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    window.destroy();
                    return;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left and event.y < tab_height) {

                        select_tab(event.x);
                        dirty = true;

                    }

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) dirty = true;

        if (dirty) paint();

    }

}

fn select_tab(x: i32) void {

    const width: i32 = @intCast(window.surface.width);
    const each = @divTrunc(width, @as(i32, @intCast(tabs.len)));

    if (each <= 0) return;

    const index: usize = @intCast(@min(@divTrunc(x, each), @as(i32, @intCast(tabs.len - 1))));

    active = @enumFromInt(index);

}

// Sampling

fn sample() void {

    const scheduler = sysinfo.read(sysinfo.SchedulerSnapshot, .scheduler) catch null;
    const processes = sysinfo.read(sysinfo.ProcessSnapshot, .processes) catch null;
    const cpu = sysinfo.read(sysinfo.CpuSnapshot, .cpu) catch null;

    var disk: ?lib.proto.filesystem.Info = null;

    if (client) |*handle| {

        disk = handle.info() catch null;

    }

    lock.acquire();
    defer lock.release();

    if (scheduler) |snapshot| {

        scheduler_snapshot = snapshot;
        have_scheduler = true;
        runqueue_history.push(total_runnable(snapshot));

    }

    if (processes) |snapshot| {

        process_snapshot = snapshot;
        have_processes = true;
        thread_history.push(snapshot.total_threads);

    }

    if (cpu) |snapshot| {

        cpu_snapshot = snapshot;
        have_cpu = true;
        busy_history.push(busy_cores(snapshot));

    }

    if (disk) |info| {

        disk_info = info;
        have_disk = true;

        const percent: u32 = if (info.block_count == 0) 0 else @intCast(info.used_blocks * 100 / info.block_count);

        disk_history.push(percent);

    }

}

fn total_runnable(snapshot: sysinfo.SchedulerSnapshot) u32 {

    var total: u32 = 0;

    for (snapshot.cores[0..@intCast(snapshot.core_count)]) |core| {

        for (core.levels[0..@intCast(snapshot.level_count)]) |count| {

            total += count;

        }

    }

    return total;

}

fn busy_cores(snapshot: sysinfo.CpuSnapshot) u32 {

    var busy: u32 = 0;

    for (snapshot.cores[0..@intCast(snapshot.core_count)]) |core| {

        if (core.online != 0 and core.current_tid != 0) busy += 1;

    }

    return busy;

}

// Rendering

fn paint() void {

    const surface = &window.surface;

    surface.fill(ui.theme.window_bg);

    paint_tabs(surface);

    lock.acquire();
    defer lock.release();

    switch (active) {

        .scheduler => paint_scheduler(surface),
        .processes => paint_processes(surface),
        .cpu => paint_cpu(surface),
        .disk => paint_disk(surface),

    }

    window.present_all() catch {};

}

fn paint_tabs(surface: *const gfx.Surface) void {

    const width: i32 = @intCast(surface.width);
    const each = @divTrunc(width, @as(i32, @intCast(tabs.len)));

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = tab_height }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = tab_height, .w = width, .h = 1 }, ui.theme.border);

    for (tabs, 0..) |tab, index| {

        const x = @as(i32, @intCast(index)) * each;
        const is_active = @intFromEnum(active) == index;

        if (is_active) {

            surface.fill_rect(.{ .x = x, .y = tab_height - 3, .w = each, .h = 3 }, ui.theme.accent);

        }

        const tint = if (is_active) ui.theme.text else ui.theme.text_dim;

        ui.icon(surface, .{ .x = x + 18, .y = 11, .w = 20, .h = 20 }, tab.icon, tint);
        ui.text_in(surface, &font, .{ .x = x + 44, .y = 0, .w = each - 48, .h = tab_height }, 0, 14, tab.label, tint);

    }

}

fn content_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return .{ .x = 16, .y = tab_height + 16, .w = width - 32, .h = height - tab_height - 32 };

}

fn paint_scheduler(surface: *const gfx.Surface) void {

    const area = content_rect();

    if (!have_scheduler) return paint_unavailable(surface, area);

    const snapshot = scheduler_snapshot;

    var header: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&header, "{d}/{d} cores online   boost {d} ms   levels {d}", .{
        snapshot.online_count,
        snapshot.core_count,
        snapshot.boost_interval_ns / 1_000_000,
        snapshot.level_count,
    }) catch "";

    ui.text(surface, &font, area.x, area.y, 13, "Runnable threads across all cores", ui.theme.text);
    ui.text(surface, &font, area.x, area.y + 20, 12, line, ui.theme.text_dim);

    const chart = Rect{ .x = area.x, .y = area.y + 44, .w = area.w, .h = @divTrunc(area.h * 3, 5) };

    ui.line_chart(surface, chart, runqueue_history.samples[0..runqueue_history.len], @max(4, runqueue_history.peak()), ui.theme.accent);

    // Per-core current occupant beneath the chart.

    var y = chart.y + chart.h + 16;
    const core_count = @min(@as(usize, @intCast(snapshot.core_count)), 8);

    for (0..core_count) |index| {

        const core = snapshot.cores[index];

        var row: [64]u8 = undefined;
        const text = format_core(&row, index, core.online != 0, core.current_pid, core.current_tid);

        ui.text(surface, &font, area.x, y, 12, text, ui.theme.text_dim);

        y += 18;

    }

}

fn paint_processes(surface: *const gfx.Surface) void {

    const area = content_rect();

    if (!have_processes) return paint_unavailable(surface, area);

    const snapshot = process_snapshot;

    var header: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&header, "{d} processes   {d} threads   {d} handles", .{
        snapshot.count,
        snapshot.total_threads,
        snapshot.total_handles,
    }) catch "";

    ui.text(surface, &font, area.x, area.y, 13, "Total threads", ui.theme.text);
    ui.text(surface, &font, area.x, area.y + 20, 12, line, ui.theme.text_dim);

    const chart = Rect{ .x = area.x, .y = area.y + 44, .w = area.w, .h = @divTrunc(area.h * 2, 5) };

    ui.line_chart(surface, chart, thread_history.samples[0..thread_history.len], @max(4, thread_history.peak()), ui.theme.good);

    var y = chart.y + chart.h + 14;

    ui.text(surface, &font, area.x, y, 12, "process", ui.theme.text_faint);
    ui.text(surface, &font, area.x + 200, y, 12, "threads", ui.theme.text_faint);
    ui.text(surface, &font, area.x + 300, y, 12, "handles", ui.theme.text_faint);

    y += 20;

    const shown = @min(@as(usize, @intCast(@min(snapshot.count, snapshot.capacity))), 7);

    for (0..shown) |index| {

        const process = snapshot.processes[index];

        if (y + 16 > area.y + area.h) break;

        ui.text(surface, &font, area.x, y, 12, process.name[0..@min(@as(usize, @intCast(process.name_len)), process.name.len)], ui.theme.text);

        var numbers: [32]u8 = undefined;
        const threads = std.fmt.bufPrint(numbers[0..16], "{d}", .{process.thread_count}) catch "";
        const handles = std.fmt.bufPrint(numbers[16..], "{d}", .{process.handle_count}) catch "";

        ui.text(surface, &font, area.x + 200, y, 12, threads, ui.theme.text_dim);
        ui.text(surface, &font, area.x + 300, y, 12, handles, ui.theme.text_dim);

        y += 18;

    }

}

fn paint_cpu(surface: *const gfx.Surface) void {

    const area = content_rect();

    if (!have_cpu) return paint_unavailable(surface, area);

    const snapshot = cpu_snapshot;

    var header: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&header, "{d}/{d} cores online   current core {d}", .{
        snapshot.online_count,
        snapshot.core_count,
        snapshot.current_core,
    }) catch "";

    ui.text(surface, &font, area.x, area.y, 13, "Busy cores", ui.theme.text);
    ui.text(surface, &font, area.x, area.y + 20, 12, line, ui.theme.text_dim);

    const chart = Rect{ .x = area.x, .y = area.y + 44, .w = area.w, .h = @divTrunc(area.h * 3, 5) };

    ui.line_chart(surface, chart, busy_history.samples[0..busy_history.len], @max(1, snapshot.core_count), ui.theme.warn);

    var y = chart.y + chart.h + 16;
    const core_count = @min(@as(usize, @intCast(snapshot.core_count)), 8);

    for (0..core_count) |index| {

        const core = snapshot.cores[index];

        var row: [64]u8 = undefined;
        const text = format_core(&row, index, core.online != 0, core.current_pid, core.current_tid);

        ui.text(surface, &font, area.x, y, 12, text, ui.theme.text_dim);

        y += 18;

    }

}

fn paint_disk(surface: *const gfx.Surface) void {

    const area = content_rect();

    if (!have_disk) return paint_unavailable(surface, area);

    const info = disk_info;

    const total_mib = info.block_count * info.block_size / (1024 * 1024);
    const used_mib = info.used_blocks * info.block_size / (1024 * 1024);
    const free_mib = info.free_blocks * info.block_size / (1024 * 1024);

    ui.text(surface, &font, area.x, area.y, 13, "Disk usage", ui.theme.text);

    const meter_rect = Rect{ .x = area.x, .y = area.y + 28, .w = area.w, .h = 26 };

    ui.meter(surface, meter_rect, info.used_blocks, info.block_count, ui.theme.accent);

    var line: [96]u8 = undefined;
    const summary = std.fmt.bufPrint(&line, "{d} MiB used of {d} MiB   ({d} MiB free)", .{ used_mib, total_mib, free_mib }) catch "";

    ui.text(surface, &font, area.x, area.y + 64, 12, summary, ui.theme.text_dim);

    const chart = Rect{ .x = area.x, .y = area.y + 92, .w = area.w, .h = @divTrunc(area.h * 2, 5) };

    ui.text(surface, &font, area.x, area.y + 92 - 20, 12, "Used %", ui.theme.text_faint);
    ui.line_chart(surface, chart, disk_history.samples[0..disk_history.len], 100, ui.theme.accent);

    var detail: [96]u8 = undefined;
    const blocks = std.fmt.bufPrint(&detail, "{d} blocks total   {d} used   {d} free   {d} inodes", .{
        info.block_count,
        info.used_blocks,
        info.free_blocks,
        info.inode_count,
    }) catch "";

    ui.text(surface, &font, area.x, chart.y + chart.h + 16, 12, blocks, ui.theme.text_dim);

}

fn paint_unavailable(surface: *const gfx.Surface, area: Rect) void {

    ui.text(surface, &font, area.x, area.y + 8, 13, "Data unavailable", ui.theme.text_dim);

}

fn format_core(buffer: []u8, index: usize, online: bool, pid: u32, tid: u32) []const u8 {

    if (!online) return std.fmt.bufPrint(buffer, "core {d}   offline", .{index}) catch "";

    if (tid == 0) return std.fmt.bufPrint(buffer, "core {d}   idle", .{index}) catch "";

    return std.fmt.bufPrint(buffer, "core {d}   running {d}/{d}", .{ index, pid, tid }) catch "";

}

// A worker thread paces the samples off real time and wakes the paint loop.

const sampler_stack_pages = 8;
const page_size = 4096;

fn start_sampler() !void {

    const stack = try sys.create(.region, sampler_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&sampler), base + sampler_stack_pages * page_size);

    try sys.start(thread);

}

fn sampler() callconv(.c) noreturn {

    while (true) {

        lib.time.sleep_ms(sample_interval_ms);

        sample();

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, lib.proto.window.ring_bit) catch {};

    }

}
