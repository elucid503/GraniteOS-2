// Software: browse, verify, install, update, and remove Granite repository packages.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const std_options = lib.rng.std_options;

pub const app_meta = .{

    .title = "Software",
    .description = "Discover and manage applications.",
    .icon = "software",
    .category = "System",

};

comptime {

    _ = lib.start;

}

const pad: i32 = 18;
const header_height: i32 = 66;
const status_height: i32 = 42;
const row_height: i32 = 72;
const button_width: i32 = 92;
const worker_stack_pages = 16;
const page_size = 4096;

const refresh_id: u32 = 1;
const action_id_base: u32 = 1000;

const Work = enum(u32) {

    idle,
    refresh,
    install,
    uninstall,

};

const Result = enum(u32) {

    idle,
    working,
    ready,
    failed,

};

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var packages: [lib.software.max_packages]lib.software.Package = undefined;
var package_count: usize = 0;
var installed: [lib.software.max_packages]lib.software.Installed = undefined;
var installed_count: usize = 0;

var repository_storage: [256]u8 = undefined;
var repository_len: usize = 0;
var message_storage: [128]u8 = undefined;
var message_len: usize = 0;

var pending_work: u32 = @intFromEnum(Work.idle);
var result_state: u32 = @intFromEnum(Result.idle);
var selected_package: usize = 0;
var scroll: usize = 0;
var running: u32 = 1;

var regions = ui.HitRegions{};

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    lib.prefs.refresh();

    if (args.len > 0) lib.wm.bind_program(args[0]);

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try lib.wm.open_main(&connection, 760, 540, "Software");

    installed_count = lib.software.load_installed(installed[0..]);

    const repository = lib.software.repository_url(&repository_storage);

    repository_len = @min(repository.len, repository_storage.len);

    if (repository.ptr != repository_storage[0..].ptr) {

        @memcpy(repository_storage[0..repository_len], repository[0..repository_len]);

    }

    try start_worker();
    begin_work(.refresh, 0);
    paint();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    lib.wm.close_main(&connection, &window);
                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    clamp_scroll();
                    dirty = true;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left) click(event.x, event.y);

                },

                events.kind_pointer_move => {

                    if (regions.pointer_move(event.x, event.y)) dirty = true;

                    update_cursor(event.x, event.y);

                },

                events.kind_scroll => {

                    if (wheel(event.value)) dirty = true;

                },

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    dirty = true;

                },

                else => {},

            }

        }

        const state: Result = @enumFromInt(@atomicLoad(u32, &result_state, .acquire));

        if (state == .ready or state == .failed) {

            @atomicStore(u32, &result_state, @intFromEnum(Result.idle), .release);
            clamp_scroll();
            dirty = true;

        }

        if (dirty) paint();

        if (connection.poll_event() != null) continue;

        _ = sys.wait(ready) catch {};

    }

}

fn begin_work(work: Work, index: usize) void {

    if (@atomicLoad(u32, &result_state, .acquire) == @intFromEnum(Result.working)) return;

    selected_package = index;
    @atomicStore(u32, &result_state, @intFromEnum(Result.working), .release);
    @atomicStore(u32, &pending_work, @intFromEnum(work), .release);

    set_message(switch (work) {

        .refresh => "Loading repository...",
        .install => "Downloading and verifying package...",
        .uninstall => "Removing package...",
        .idle => "",

    });

    paint();

}

fn click(x: i32, y: i32) void {

    const id = regions.hit(x, y);

    if (id == refresh_id) {

        begin_work(.refresh, 0);
        return;

    }

    if (id < action_id_base) return;

    const index: usize = id - action_id_base;

    if (index >= package_count) return;

    if (installed_index(packages[index].program())) |found| {

        begin_work(if (lib.software.is_update(&packages[index], &installed[found])) .install else .uninstall, index);

    } else {

        begin_work(.install, index);

    }

}

fn update_cursor(x: i32, y: i32) void {

    if (regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker) else lib.cursor.set(&connection, .pointer);

}

fn wheel(delta: i64) bool {

    const before = scroll;
    const model = scroll_model();

    scroll = @intCast(model.wheel(delta, 1));

    return scroll != before;

}

fn visible_rows() usize {

    const height: i32 = @intCast(window.surface.height);
    const available = height - header_height - status_height - pad;

    return @max(@as(usize, 1), @as(usize, @intCast(@max(0, @divTrunc(available, row_height)))));

}

fn scroll_model() ui.Scroll {

    return .{

        .offset = @intCast(scroll),
        .content = @intCast(package_count),
        .viewport = @intCast(visible_rows()),

    };

}

fn clamp_scroll() void {

    scroll = @intCast(scroll_model().clamped());

}

fn installed_index(id: []const u8) ?usize {

    return lib.software.find_installed(installed[0..installed_count], id);

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    surface.fill(ui.theme.window_bg);
    regions.reset();

    paint_header(surface, width);
    paint_status(surface, width);

    if (package_count == 0) {

        const state: Result = @enumFromInt(@atomicLoad(u32, &result_state, .acquire));
        const text = if (state == .working) "Connecting to repository..." else "No packages are available.";

        text_center(surface, .{

            .x = pad,
            .y = header_height + status_height,
            .w = width - pad * 2,
            .h = height - header_height - status_height,

        }, 14, text, ui.theme.text_dim);

    } else {

        paint_packages(surface, width, height);

    }

    window.present_all() catch {};

}

fn paint_header(surface: *const gfx.Surface, width: i32) void {

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = header_height }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = header_height - 1, .w = width, .h = 1 }, ui.theme.border);

    lib.draw.vector.icon_in(surface, .{

        .x = pad,
        .y = 19,
        .w = 28,
        .h = 28,

    }, lib.icons.software, ui.theme.accent);

    font.draw(surface, pad + 42, 13, 20, "Software", ui.theme.text);
    font.draw(surface, pad + 42, 38, 12, "Apps for GraniteOS 2", ui.theme.text_dim);

    const button = Rect{

        .x = width - pad - 94,
        .y = 15,
        .w = 94,
        .h = 36,

    };

    const working = @atomicLoad(u32, &result_state, .acquire) == @intFromEnum(Result.working);

    if (!working) regions.add(refresh_id, button);

    ui.widgets.button(surface, &font, button, if (working) "Working..." else "Refresh", .{

        .hovered = regions.hovered(refresh_id),
        .outlined = true,

    }, .{

        .size = 12,
        .color = if (working) ui.theme.text_dim else ui.theme.text,
        .idle = ui.theme.surface,

    });

}

fn paint_status(surface: *const gfx.Surface, width: i32) void {

    const y = header_height;
    const state: Result = @enumFromInt(@atomicLoad(u32, &result_state, .acquire));
    const color = if (state == .failed) ui.theme.warn else if (state == .ready) ui.theme.good else ui.theme.text_dim;
    const message = message_storage[0..message_len];

    font.draw(surface, pad, y + 7, 12, if (message.len == 0) "Ready" else message, color);

    const url = repository_storage[0..repository_len];
    const visible = ui.truncate(&font, url, 10, width - pad * 2);

    font.draw(surface, pad, y + 25, 10, visible, ui.theme.text_faint);

}

fn paint_packages(surface: *const gfx.Surface, width: i32, height: i32) void {

    const top = header_height + status_height;
    const shown = visible_rows();
    const end = @min(package_count, scroll + shown);
    var index = scroll;

    while (index < end) : (index += 1) {

        const package = &packages[index];
        const visible = index - scroll;
        const row = Rect{

            .x = pad,
            .y = top + @as(i32, @intCast(visible)) * row_height,
            .w = width - pad * 2 - ui.scrollbar_width - 6,
            .h = row_height - 6,

        };
        const id = action_id_base + @as(u32, @intCast(index));
        const action = Rect{

            .x = row.x + row.w - button_width - 10,
            .y = row.y + @divTrunc(row.h - 34, 2),
            .w = button_width,
            .h = 34,

        };

        ui.fill_round_rect(surface, row, 7, ui.theme.surface);
        ui.stroke_round_rect(surface, row, 7, 1, ui.theme.border);

        lib.draw.vector.icon_in(surface, .{

            .x = row.x + 12,
            .y = row.y + 18,
            .w = 28,
            .h = 28,

        }, lib.icons.get(package.icon_name()), ui.theme.accent);

        font.draw(surface, row.x + 52, row.y + 9, 14, package.title(), ui.theme.text);
        font.draw(surface, row.x + 52, row.y + 31, 11, ui.truncate(&font, package.description(), 11, row.w - button_width - 86), ui.theme.text_dim);

        var version_buffer: [48]u8 = undefined;
        const version = std.fmt.bufPrint(&version_buffer, "Version {s}", .{package.release()}) catch package.release();

        font.draw(surface, row.x + 52, row.y + 49, 10, version, ui.theme.text_faint);

        const found = installed_index(package.program());
        const label: []const u8 = if (found) |installed_at|
            if (lib.software.is_update(package, &installed[installed_at])) "Update" else "Uninstall"
        else
            "Install";
        const working = @atomicLoad(u32, &result_state, .acquire) == @intFromEnum(Result.working);

        if (!working) regions.add(id, action);

        ui.widgets.button(surface, &font, action, label, .{

            .hovered = regions.hovered(id),
            .accent = found == null or (found != null and lib.software.is_update(package, &installed[found.?])),

        }, .{ .size = 12, .color = if (working) ui.theme.text_dim else ui.theme.text });

    }

    ui.scrollbar(surface, .{

        .x = width - pad - ui.scrollbar_width,
        .y = top,
        .w = ui.scrollbar_width,
        .h = height - top - pad,

    }, scroll_model());

}

fn text_center(surface: *const gfx.Surface, rect: Rect, size: u32, text: []const u8, color: gfx.Color) void {

    const x = rect.x + @divTrunc(rect.w - font.text_width(text, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, text, color);

}

fn set_message(text: []const u8) void {

    const length = @min(text.len, message_storage.len);

    @memcpy(message_storage[0..length], text[0..length]);
    message_len = length;

}

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    var heap = lib.mem.Heap.init(cap.memory);

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        const raw = @atomicRmw(u32, &pending_work, .Xchg, @intFromEnum(Work.idle), .acquire);
        const work: Work = @enumFromInt(raw);

        if (work == .idle) {

            lib.time.sleep_ms(20);
            continue;

        }

        run_work(&heap, work) catch |failure| {

            set_message(failure_text(failure));
            @atomicStore(u32, &result_state, @intFromEnum(Result.failed), .release);
            sys.notify(ready, proto.window.ring_bit) catch {};
            continue;

        };

        @atomicStore(u32, &result_state, @intFromEnum(Result.ready), .release);
        sys.notify(ready, proto.window.ring_bit) catch {};

    }

    while (true) lib.time.sleep_ms(1000);

}

fn run_work(heap: *lib.mem.Heap, work: Work) !void {

    switch (work) {

        .refresh => try refresh_repository(heap),

        .install => {

            if (selected_package >= package_count) return error.InvalidPackage;

            try install_package(heap, &packages[selected_package]);
            installed_count = lib.software.load_installed(installed[0..]);
            set_message("Package installed and added to the launcher.");

        },

        .uninstall => {

            if (selected_package >= package_count) return error.InvalidPackage;

            try lib.software.uninstall(packages[selected_package].program());
            installed_count = lib.software.load_installed(installed[0..]);
            set_message("Package removed.");

        },

        .idle => {},

    }

}

fn refresh_repository(heap: *lib.mem.Heap) !void {

    const buffer = try heap.alloc(128 * 1024);
    defer heap.free(buffer);

    const response = try lib.http.request(cap.memory, heap, .{

        .url = repository_storage[0..repository_len],

    }, buffer);

    if (response.status != 200) return error.InvalidRepository;

    package_count = try lib.software.parse_index(heap, response.body, packages[0..]);
    installed_count = lib.software.load_installed(installed[0..]);

    var status_buffer: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "{d} packages available, {d} installed.", .{ package_count, installed_count }) catch "Repository loaded.";

    set_message(status);

}

fn install_package(heap: *lib.mem.Heap, package: *const lib.software.Package) !void {

    const buffer = try heap.alloc(lib.software.max_binary + 16 * 1024);
    defer heap.free(buffer);

    const response = try lib.http.request(cap.memory, heap, .{

        .url = package.url(),

    }, buffer);

    if (response.status != 200) return error.InvalidPackage;

    try lib.software.install(package, response.body);

}

fn failure_text(failure: anyerror) []const u8 {

    return switch (failure) {

        error.InvalidRepository => "Repository returned an invalid response.",
        error.Incompatible => "Repository targets an incompatible GraniteOS ABI.",
        error.HashMismatch => "Package verification failed; nothing was installed.",
        error.InvalidPackage => "The package is not a valid GraniteOS executable.",
        error.BuiltinConflict => "Package ID conflicts with built-in software.",
        error.TooLarge => "Package or repository exceeds the supported size.",
        error.NotFound => "Package or repository was not found.",
        error.NoMemory => "Not enough memory or disk space.",
        error.Timeout => "The repository request timed out.",

        else => "Software could not complete the request.",

    };

}
