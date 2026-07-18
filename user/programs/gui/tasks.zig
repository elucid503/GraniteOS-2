// Task Manager: a conservative, single-threaded view of kernel process snapshots.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sysinfo = lib.sysinfo;
const ui = lib.ui;

pub const app_meta = .{
    .title = "Task Manager",
    .description = "Monitor active processes.",
    .icon = "cpu",
    .category = "System",
};

comptime {

    _ = lib.start;

}

const header_h: i32 = 72;
const item_h: i32 = 34;
const pad: i32 = 18;

const Item = union(enum) {

    heading: []const u8,
    process: usize,

};

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var snapshot: sysinfo.ProcessSnapshot = undefined;
var have_snapshot = false;
var apps: [32]lib.wm.App = undefined;
var apps_len: usize = 0;
var items: [sysinfo.max_processes + 2]Item = undefined;
var items_len: usize = 0;
var scroll_row: usize = 0;
var selected_pid: u32 = 0;
var pointer_x: i32 = -1;
var pointer_y: i32 = -1;
var focus_rect = gfx.Rect.empty;
var end_rect = gfx.Rect.empty;
var dragging_scrollbar = false;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);
    apps_len = lib.wm.load_apps(&bundle, &apps);
    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(680, 500, lib.proto.window.flag_quartz, "Task Manager");

    refresh();
    paint();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return;

            },
            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                clamp_scroll();
                paint();

            },
            events.kind_scroll => {

                if (wheel(event.value)) paint();

            },
            events.kind_pointer_move => {

                const was_focus_hovered = focus_rect.contains(pointer_x, pointer_y);
                const was_end_hovered = end_rect.contains(pointer_x, pointer_y);

                pointer_x = event.x;
                pointer_y = event.y;

                if (dragging_scrollbar) {

                    if (drag_scrollbar(event.y)) paint();
                    continue;

                }

                const over_app = if (row_process(event.y)) |process| !is_system(process) else false;

                lib.cursor.set(&connection, if (over_app or focus_rect.contains(event.x, event.y) or end_rect.contains(event.x, event.y)) .clicker else .pointer);

                const focus_hovered = focus_rect.contains(pointer_x, pointer_y);
                const end_hovered = end_rect.contains(pointer_x, pointer_y);

                if (was_focus_hovered != focus_hovered or was_end_hovered != end_hovered) paint();

            },
            events.kind_button_down => if (event.code == events.button_left) {

                var changed = false;

                if (scrollbar_rect().contains(event.x, event.y) and item_count() > visible_rows()) {

                    dragging_scrollbar = true;
                    changed = drag_scrollbar(event.y);

                } else changed = click(event.x, event.y);

                if (changed) paint();

            },
            events.kind_button_up => {

                if (event.code == events.button_left) dragging_scrollbar = false;

            },
            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                paint();

            },
            events.kind_window_focus => {

                refresh();
                paint();

            },
            else => {},

        }

    }

}

fn row_process(y: i32) ?*const sysinfo.ProcessInfo {

    if (y < header_h) return null;

    const row: usize = @intCast(@divTrunc(y - header_h, item_h));
    const item = item_at(scroll_row + row) orelse return null;

    return switch (item) {

        .heading => null,
        .process => |index| &snapshot.processes[index],

    };

}

fn click(x: i32, y: i32) bool {

    if (focus_rect.contains(x, y) or end_rect.contains(x, y)) {

        const process = selected_process() orelse return false;
        var title_buffer: [sysinfo.process_name_bytes]u8 = undefined;
        const title = app_title(process, &title_buffer) orelse return false;

        if (focus_rect.contains(x, y)) lib.wm.activate_title(&connection, title) catch {};
        if (end_rect.contains(x, y) and matching_instances(process) == 1) lib.wm.close_title(&connection, title) catch {};

        return false;

    }

    if (row_process(y)) |process| {

        if (!is_system(process) and selected_pid != process.pid) {

            selected_pid = process.pid;
            return true;

        }

    }

    return false;

}

fn selected_process() ?*const sysinfo.ProcessInfo {

    for (snapshot.processes[0..process_count()]) |*process| {

        if (process.pid == selected_pid) return process;

    }

    return null;

}

fn refresh() void {

    snapshot = sysinfo.read(sysinfo.ProcessSnapshot, .processes) catch {

        have_snapshot = false;
        items_len = 0;
        scroll_row = 0;
        return;

    };

    have_snapshot = true;
    rebuild_items();

    if (selected_process() == null) selected_pid = 0;

    clamp_scroll();

}

fn process_count() usize {

    if (!have_snapshot) return 0;

    return @min(@as(usize, @intCast(@min(snapshot.count, snapshot.capacity))), sysinfo.max_processes);

}

fn item_count() usize {

    return items_len;

}

fn item_at(wanted: usize) ?Item {

    return if (wanted < items_len) items[wanted] else null;

}

fn rebuild_items() void {

    items_len = 0;
    items[items_len] = .{ .heading = "Apps" };
    items_len += 1;

    for (snapshot.processes[0..process_count()], 0..) |*process, index| {

        if (is_system(process)) continue;

        items[items_len] = .{ .process = index };
        items_len += 1;

    }

    items[items_len] = .{ .heading = "System Processes" };
    items_len += 1;

    for (snapshot.processes[0..process_count()], 0..) |*process, index| {

        if (!is_system(process)) continue;

        items[items_len] = .{ .process = index };
        items_len += 1;

    }

}

fn process_name(process: *const sysinfo.ProcessInfo, out: *[sysinfo.process_name_bytes]u8) []const u8 {

    const length = @min(@as(usize, @intCast(process.name_len)), process.name.len);

    @memcpy(out[0..length], process.name[0..length]);

    return out[0..length];

}

fn app_title(process: *const sysinfo.ProcessInfo, out: *[sysinfo.process_name_bytes]u8) ?[]const u8 {

    const name = process_name(process, out);

    for (apps[0..apps_len]) |app| {

        if (std.mem.eql(u8, name, app.program)) return app.title;

    }

    return null;

}

fn is_system(process: *const sysinfo.ProcessInfo) bool {

    var buffer: [sysinfo.process_name_bytes]u8 = undefined;

    return app_title(process, &buffer) == null;

}

fn visible_rows() usize {

    const available = @max(0, @as(i32, @intCast(window.surface.height)) - header_h);

    return @max(1, @as(usize, @intCast(@divTrunc(available, item_h))));

}

fn max_scroll() usize {

    const count = item_count();
    const visible = visible_rows();

    return if (count > visible) count - visible else 0;

}

fn clamp_scroll() void {

    scroll_row = @min(scroll_row, max_scroll());

}

fn wheel(delta: i64) bool {

    const before = scroll_row;
    scroll_row = @intCast(scroll_model().wheel(delta, 3));

    return scroll_row != before;

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    focus_rect = gfx.Rect.empty;
    end_rect = gfx.Rect.empty;

    lib.quartz.fill_window(surface, ui.theme.window_bg, @intFromEnum(lib.prefs.quartz_level));
    font.draw(surface, pad, 16, 22, "Task Manager", ui.theme.text);

    if (!have_snapshot) {

        font.draw(surface, pad, 48, 12, "Process information unavailable", ui.theme.text_dim);
        window.present_all() catch {};
        return;

    }

    var summary_buffer: [80]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buffer, "{d} {s}  /  {d} {s}  /  {d} {s}", .{

        snapshot.count,
        plural(snapshot.count, "process", "processes"),
        snapshot.total_threads,
        plural(snapshot.total_threads, "thread", "threads"),
        snapshot.total_handles,
        plural(snapshot.total_handles, "handle", "handles"),

    }) catch "Processes";
    font.draw(surface, pad, 47, 12, summary, ui.theme.text_dim);

    const rows = visible_rows();
    var row: usize = 0;

    while (row < rows) : (row += 1) {

        const item = item_at(scroll_row + row) orelse break;
        const y = header_h + @as(i32, @intCast(row)) * item_h;

        switch (item) {

            .heading => |label| paint_heading(surface, width, y, label),
            .process => |index| paint_process(surface, width, y, &snapshot.processes[index]),

        }

    }

    paint_scrollbar(surface);
    window.present_all() catch {};

}

fn paint_heading(surface: *const gfx.Surface, width: i32, y: i32, label: []const u8) void {

    font.draw(surface, pad, y + 9, 11, label, ui.theme.text_faint);
    const start = pad + font.text_width(label, 11) + 12;
    surface.fill_rect(.{ .x = start, .y = y + 16, .w = @max(0, width - start - pad), .h = 1 }, ui.theme.border);

}

fn paint_process(surface: *const gfx.Surface, width: i32, y: i32, process: *const sysinfo.ProcessInfo) void {

    var name_buffer: [sysinfo.process_name_bytes]u8 = undefined;
    const name = process_name(process, &name_buffer);
    const system = is_system(process);
    const name_color = if (system) ui.theme.text_dim else ui.theme.text;
    const detail_color = if (system) ui.theme.text_faint else ui.theme.text_dim;

    font.draw(surface, pad + 10, y + 8, 13, name, name_color);

    var detail_buffer: [80]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, "PID {d}    {d} {s}    {d} {s}    {d} KiB", .{

        process.pid,
        process.thread_count,
        plural(process.thread_count, "thread", "threads"),
        process.handle_count,
        plural(process.handle_count, "handle", "handles"),
        process.memory_bytes / 1024,

    }) catch "";
    font.draw(surface, @min(width - 300, 205), y + 9, 12, detail, detail_color);

    if (system or process.pid != selected_pid) return;

    const self = std.mem.eql(u8, name, "tasks");
    if (self or width < 520) return;

    const can_end = matching_instances(process) == 1;
    const right = width - pad - ui.scrollbar_width - 6;

    if (can_end) {

        end_rect = .{ .x = right - 64, .y = y + 3, .w = 64, .h = 28 };
        ui.widgets.button(surface, &font, end_rect, "End", .{ .hovered = end_rect.contains(pointer_x, pointer_y), .accent = true }, .{ .size = 12 });

    }

    focus_rect = .{ .x = right - (if (can_end) @as(i32, 140) else 70), .y = y + 3, .w = 68, .h = 28 };
    ui.widgets.button(surface, &font, focus_rect, "Focus", .{ .hovered = focus_rect.contains(pointer_x, pointer_y), .outlined = true }, .{ .size = 12 });

}

fn paint_scrollbar(surface: *const gfx.Surface) void {

    const count = item_count();
    const visible = visible_rows();

    if (count <= visible) return;

    ui.scrollbar(surface, scrollbar_rect(), scroll_model());

}

fn scrollbar_rect() gfx.Rect {

    return .{

        .x = @as(i32, @intCast(window.surface.width)) - ui.scrollbar_width - 3,
        .y = header_h + 4,
        .w = ui.scrollbar_width,
        .h = @max(0, @as(i32, @intCast(window.surface.height)) - header_h - 8),

    };

}

fn scroll_model() ui.Scroll {

    return .{

        .offset = @intCast(scroll_row),
        .content = @intCast(item_count()),
        .viewport = @intCast(visible_rows()),

    };

}

fn drag_scrollbar(y: i32) bool {

    const track = scrollbar_rect();
    const before = scroll_row;

    scroll_row = @intCast(scroll_model().offset_at(track.h, y - track.y));

    return scroll_row != before;

}

fn matching_instances(process: *const sysinfo.ProcessInfo) usize {

    var source_buffer: [sysinfo.process_name_bytes]u8 = undefined;
    const source = app_title(process, &source_buffer) orelse return 0;
    var count: usize = 0;

    for (snapshot.processes[0..process_count()]) |*candidate| {

        var candidate_buffer: [sysinfo.process_name_bytes]u8 = undefined;
        const candidate_title = app_title(candidate, &candidate_buffer) orelse continue;

        if (std.ascii.eqlIgnoreCase(source, candidate_title)) count += 1;

    }

    return count;

}

fn plural(count: anytype, singular: []const u8, multiple: []const u8) []const u8 {

    return if (count == 1) singular else multiple;

}
