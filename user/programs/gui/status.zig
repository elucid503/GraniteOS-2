// Status: a live system monitor.

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

pub const app_meta = .{
    .title = "Status",
    .description = "Live system metrics",
    .icon = "chart",
};

comptime {

    _ = lib.start;

}

const tab_height: i32 = 42;
const sample_interval_ms = 1000;
const history_span = 64;
const used_section_gap: i32 = 28;
const used_label_chart_gap: i32 = 20;
const max_pie_entries = 5;
const gantt_label_w: i32 = 56;

const pie_colors = [_]gfx.Color{
    ui.theme.text,
    ui.theme.text_dim,
    ui.theme.accent,
    ui.theme.accent_dim,
    ui.theme.text_faint,
    ui.theme.surface_alt,
};

const MemoryRank = struct {

    value: u64,
    name_buf: [sysinfo.process_name_bytes]u8 = [_]u8{0} ** sysinfo.process_name_bytes,
    name_len: u8 = 0,

    fn set_label(self: *MemoryRank, text: []const u8) void {

        const length = @min(text.len, self.name_buf.len);

        @memset(&self.name_buf, 0);
        @memcpy(self.name_buf[0..length], text[0..length]);
        self.name_len = @intCast(length);

    }

    fn label(self: *const MemoryRank) []const u8 {

        return self.name_buf[0..self.name_len];

    }

};

const Tab = enum(usize) {

    scheduler = 0,
    processes,
    cpu,
    disk,
    memory,

};

const tabs = [_]struct { label: []const u8, icon: []const u8 }{

    .{ .label = "Scheduler", .icon = lib.icons.apps },
    .{ .label = "Processes", .icon = lib.icons.chart },
    .{ .label = "CPU", .icon = lib.icons.cpu },
    .{ .label = "Disk", .icon = lib.icons.disk },
    .{ .label = "Memory", .icon = lib.icons.memory },

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

const GanttHistory = struct {

    samples: [history_span]ui.GanttSample = [_]ui.GanttSample{.{ .pid = 0, .tid = 0 }} ** history_span,
    len: usize = 0,

    fn push(self: *GanttHistory, pid: u32, tid: u32) void {

        const span = ui.GanttSample{ .pid = pid, .tid = tid };

        if (self.len < history_span) {

            self.samples[self.len] = span;
            self.len += 1;

            return;

        }

        var index: usize = 1;

        while (index < history_span) : (index += 1) {

            self.samples[index - 1] = self.samples[index];

        }

        self.samples[history_span - 1] = span;

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
var memory_snapshot: sysinfo.MemorySnapshot = undefined;
var have_scheduler = false;
var have_processes = false;
var have_cpu = false;
var have_memory = false;

var disk_info: lib.proto.filesystem.Info = undefined;
var have_disk = false;
var client: ?lib.fs.Client = null;

var gantt_history = [_]GanttHistory{.{}} ** sysinfo.scheduling_levels;
var thread_history = History{};
var busy_history = History{};
var disk_history = History{};
var memory_history = History{};

var ready: cap.Handle = 0;
var tick: u32 = 0;
var running: u32 = 1;

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

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    window.destroy();
                    return;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left and event.y < tab_height) {

                        select_tab(event.x);
                        dirty = true;

                    }

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) dirty = true;

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

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
    const memory = sysinfo.read(sysinfo.MemorySnapshot, .memory) catch null;

    var disk: ?lib.proto.filesystem.Info = null;

    if (client) |*handle| {

        disk = handle.info() catch null;

    }

    lock.acquire();
    defer lock.release();

    if (scheduler) |snapshot| {

        scheduler_snapshot = snapshot;
        have_scheduler = true;

        const levels = @min(@as(usize, @intCast(snapshot.level_count)), sysinfo.scheduling_levels);

        for (0..levels) |index| {

            const level = snapshot.level_queues[index];

            gantt_history[index].push(level.lead_pid, level.lead_tid);

        }

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

    if (memory) |snapshot| {

        memory_snapshot = snapshot;
        have_memory = true;

        const used = snapshot.total_frames - snapshot.free_frames;
        const percent: u32 = if (snapshot.total_frames == 0) 0 else @intCast(used * 100 / snapshot.total_frames);

        memory_history.push(percent);

    }

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
        .memory => paint_memory(surface),

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
    const line = std.fmt.bufPrint(&header, "{d}/{d} cores online   boost {d} ms   {d} levels", .{
        snapshot.online_count,
        snapshot.core_count,
        snapshot.boost_interval_ns / 1_000_000,
        snapshot.level_count,
    }) catch "";

    ui.text(surface, &font, area.x, area.y, 13, "Runnable threads per level", ui.theme.text);
    ui.text(surface, &font, area.x, area.y + 20, 12, line, ui.theme.text_dim);

    const chart_top = area.y + 44;
    const chart_h = area.h - 64;
    const level_count = @min(@as(usize, @intCast(snapshot.level_count)), sysinfo.scheduling_levels);
    const row_h = if (level_count == 0) chart_h else @divTrunc(chart_h, @as(i32, @intCast(level_count)));

    var rows: [sysinfo.scheduling_levels][]const ui.GanttSample = undefined;

    for (0..level_count) |index| {

        rows[index] = gantt_history[index].samples[0..gantt_history[index].len];

        var label: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&label, "level-{d}", .{ index }) catch "";

        ui.text(surface, &font, area.x, chart_top + @as(i32, @intCast(index)) * row_h + @divTrunc(row_h - 12, 2), 11, name, ui.theme.text_faint);

    }

    const chart = Rect{ .x = area.x + gantt_label_w, .y = chart_top, .w = area.w - gantt_label_w, .h = chart_h };

    ui.gantt_chart(surface, chart, rows[0..level_count]);

    ui.text(surface, &font, chart.x, chart.y + chart.h + 6, 11, "older", ui.theme.text_faint);

    var now_label: [8]u8 = undefined;
    const now_text = std.fmt.bufPrint(&now_label, "now", .{}) catch "now";

    ui.text(surface, &font, chart.x + chart.w - font.text_width(now_text, 11), chart.y + chart.h + 6, 11, now_text, ui.theme.text_faint);

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

    const used_label_y = area.y + 64 + 12 + used_section_gap;
    const chart = Rect{ .x = area.x, .y = used_label_y + used_label_chart_gap, .w = area.w, .h = @divTrunc(area.h * 2, 5) };

    ui.text(surface, &font, area.x, used_label_y, 12, "Used %", ui.theme.text_faint);
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

fn paint_memory(surface: *const gfx.Surface) void {

    const area = content_rect();

    if (!have_memory) return paint_unavailable(surface, area);

    const snapshot = memory_snapshot;
    const used_frames = snapshot.total_frames - snapshot.free_frames;
    const bytes_per_page: u64 = snapshot.page_size;
    const total_mib = snapshot.total_frames * bytes_per_page / (1024 * 1024);
    const used_mib = used_frames * bytes_per_page / (1024 * 1024);
    const free_mib = snapshot.free_frames * bytes_per_page / (1024 * 1024);

    ui.text(surface, &font, area.x, area.y, 13, "Physical memory", ui.theme.text);

    const meter_rect = Rect{ .x = area.x, .y = area.y + 28, .w = area.w, .h = 26 };

    ui.meter(surface, meter_rect, used_frames, snapshot.total_frames, ui.theme.accent);

    var line: [96]u8 = undefined;
    const summary = std.fmt.bufPrint(&line, "{d} MiB used of {d} MiB   ({d} MiB free)", .{ used_mib, total_mib, free_mib }) catch "";

    ui.text(surface, &font, area.x, area.y + 64, 12, summary, ui.theme.text_dim);

    const split_top = area.y + 88;
    const split_gap: i32 = 16;
    const half_w = @divTrunc(area.w - split_gap, 2);
    const left_x = area.x;
    const right_x = area.x + half_w + split_gap;
    const split_h = area.y + area.h - split_top - 36;

    ui.text(surface, &font, left_x, split_top, 12, "Used %", ui.theme.text_faint);

    const used_chart = Rect{
        .x = left_x,
        .y = split_top + used_label_chart_gap,
        .w = half_w,
        .h = split_h - used_label_chart_gap,
    };

    ui.line_chart(surface, used_chart, memory_history.samples[0..memory_history.len], 100, ui.theme.good);

    if (have_processes) {

        var entries: [max_pie_entries + 1]MemoryRank = undefined;
        var entry_count: usize = 0;

        rank_memory_processes(process_snapshot, &entries, &entry_count);

        if (entry_count > 0) {

            ui.text(surface, &font, right_x, split_top, 12, "By process", ui.theme.text_faint);

            const legend_cols: i32 = 3;
            const legend_row_count: i32 = 2;
            const legend_row_h: i32 = 14;
            const legend_gap: i32 = 16;
            const legend_h = legend_row_count * legend_row_h + legend_gap;
            const pie_area_h = split_h - used_label_chart_gap - legend_h;
            const pie_radius = @min(@divTrunc(half_w, 2) - 4, @max(20, @divTrunc(pie_area_h, 2) - 4));
            const pie_cx = right_x + @divTrunc(half_w, 2);
            const pie_cy = split_top + used_label_chart_gap + pie_radius + 4;

            var slices: [max_pie_entries + 1]ui.PieSlice = undefined;
            var total: u64 = 0;

            for (entries[0..entry_count]) |entry| total += entry.value;

            for (entries[0..entry_count], 0..) |entry, index| {

                slices[index] = .{
                    .value = entry.value,
                    .color = pie_colors[index % pie_colors.len],
                };

            }

            ui.pie_chart(surface, pie_cx, pie_cy, pie_radius, slices[0..entry_count]);

            const legend_y = pie_cy + pie_radius + legend_gap;
            const legend_col_w = @divTrunc(half_w, legend_cols);

            for (entries[0..entry_count], 0..) |entry, index| {

                const color = pie_colors[index % pie_colors.len];
                const percent: u64 = if (total == 0) 0 else entry.value * 100 / total;
                const row = @as(i32, @intCast(index / @as(usize, @intCast(legend_cols))));
                const col = @as(i32, @intCast(index % @as(usize, @intCast(legend_cols))));
                const col_x = right_x + col * legend_col_w;
                const row_y = legend_y + row * legend_row_h;

                surface.fill_rect(.{ .x = col_x, .y = row_y + 3, .w = 6, .h = 6 }, color);

                var legend: [48]u8 = undefined;
                const text = std.fmt.bufPrint(&legend, "{s}  {d}%", .{ entry.label(), percent }) catch "";

                ui.text_in(surface, &font, .{ .x = col_x + 12, .y = row_y, .w = legend_col_w - 12, .h = legend_row_h }, 0, 11, text, ui.theme.text_dim);

            }

        }

    }

    var detail: [96]u8 = undefined;
    const frames = std.fmt.bufPrint(&detail, "{d} frames total   {d} used   {d} free   {d}B pages", .{
        snapshot.total_frames,
        used_frames,
        snapshot.free_frames,
        bytes_per_page,
    }) catch "";

    ui.text(surface, &font, area.x, area.y + area.h - 16, 12, frames, ui.theme.text_dim);

}

fn rank_memory_processes(snapshot: sysinfo.ProcessSnapshot, entries: *[max_pie_entries + 1]MemoryRank, count: *usize) void {

    const shown = @min(@as(usize, @intCast(@min(snapshot.count, snapshot.capacity))), sysinfo.max_processes);

    var ranked: [sysinfo.max_processes]MemoryRank = undefined;
    var ranked_len: usize = 0;

    for (0..shown) |index| {

        const process = snapshot.processes[index];

        if (process.memory_bytes == 0) continue;

        const name_len = @min(@as(usize, @intCast(process.name_len)), process.name.len);

        ranked[ranked_len] = .{ .value = process.memory_bytes };
        ranked[ranked_len].set_label(process.name[0..name_len]);

        ranked_len += 1;

    }

    var index: usize = 0;

    while (index < ranked_len) : (index += 1) {

        var next = index + 1;

        while (next < ranked_len) : (next += 1) {

            if (ranked[next].value > ranked[index].value) {

                const swap = ranked[index];
                ranked[index] = ranked[next];
                ranked[next] = swap;

            }

        }

    }

    count.* = 0;
    var other: u64 = 0;

    index = 0;

    while (index < ranked_len) : (index += 1) {

        if (index < max_pie_entries) {

            entries[count.*] = ranked[index];
            count.* += 1;

        } else {

            other += ranked[index].value;

        }

    }

    if (other > 0) {

        entries[count.*] = .{ .value = other };
        entries[count.*].set_label("other");
        count.* += 1;

    }

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

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn sampler() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        lib.time.sleep_ms(sample_interval_ms);

        if (@atomicLoad(u32, &running, .acquire) == 0) break;

        sample();

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, lib.proto.window.ring_bit) catch {};

    }

    lib.start.exit();

}
