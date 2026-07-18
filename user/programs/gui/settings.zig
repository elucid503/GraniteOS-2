// Theme and temperature-unit preferences; timezone comes from Metrics at boot.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ui = lib.ui;

pub const app_meta = .{
    .title = "Settings",
    .description = "Manage the theme and more.",
    .icon = "settings",
    .category = "System",
};

comptime {

    _ = lib.start;

}

const pad: i32 = 24;
const swatch_size: i32 = 36;
const theme_col_w: i32 = 88;
const unit_btn_w: i32 = 100;
const unit_btn_h: i32 = 36;
const swatch_id_base: u32 = 100;
const unit_celsius_id: u32 = 200;
const unit_fahrenheit_id: u32 = 201;
const quartz_id_base: u32 = 300;

var font: lib.draw.text.Face = undefined;
var page: ui.Page = .{ .font = &font };

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(520, 430, lib.proto.window.flag_quartz, "Settings");

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
                paint();

            },

            events.kind_button_down => {

                if (event.code == events.button_left) click(event.x, event.y);

            },

            events.kind_pointer_move => update_cursor(event.x, event.y),

            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                paint();

            },

            else => {},

        }

    }

}

fn click(x: i32, y: i32) void {

    const hit = page.hit(x, y);

    if (hit >= swatch_id_base and hit < swatch_id_base + lib.prefs.theme_count) {

        const col = hit - swatch_id_base;

        lib.prefs.apply_theme(@enumFromInt(@as(u8, @intCast(col))));
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);
        paint();

        return;

    }

    if (hit == unit_celsius_id or hit == unit_fahrenheit_id) {

        const next: lib.prefs.TempUnit = if (hit == unit_fahrenheit_id) .fahrenheit else .celsius;

        if (lib.prefs.temp_unit == next) return;

        lib.prefs.temp_unit = next;
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);
        paint();

        return;

    }

    if (hit >= quartz_id_base and hit < quartz_id_base + lib.prefs.quartz_level_count) {

        const index = hit - quartz_id_base;
        const next: lib.prefs.QuartzLevel = @enumFromInt(@as(u8, @intCast(index)));

        if (lib.prefs.quartz_level == next) return;

        lib.prefs.quartz_level = next;
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);
        paint();

    }

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    lib.quartz.fill_window(surface, ui.theme.window_bg, @intFromEnum(lib.prefs.quartz_level));

    page.begin(width, height, .{

        .direction = .column,
        .width = .{ .px = width },
        .height = .{ .px = height },
        .padding = ui.Edge.all(pad),
        .gap = 18,

    });

    _ = page.label(ui.Page.root, "Settings", .{

        .size = 18,
        .color = ui.theme.text,

    });

    const content = page.box(ui.Page.root, .{

        .direction = .column,
        .gap = 18,

    });

    paint_theme_section(content);
    paint_quartz_section(content);
    paint_temp_section(content);

    page.end();
    page.paint(surface);

    window.present_all() catch {};

}

fn paint_quartz_section(parent: i16) void {

    const section = page.box(parent, .{

        .direction = .column,
        .gap = 14,

    });

    _ = page.label(section, "Quartz", .{

        .size = 14,
        .color = ui.theme.text,

    });

    const row = page.box(section, .{

        .direction = .row,
        .gap = 8,

    });

    for (lib.prefs.quartz_level_names, 0..) |name, index| {

        const selected = @intFromEnum(lib.prefs.quartz_level) == index;
        const id = quartz_id_base + @as(u32, @intCast(index));

        paint_choice_button(row, id, name, selected);

    }

}

fn paint_theme_section(parent: i16) void {

    const section = page.box(parent, .{

        .direction = .column,
        .gap = 14,

    });

    _ = page.label(section, "Color theme", .{

        .size = 14,
        .color = ui.theme.text,

    });

    const row = page.box(section, .{

        .direction = .row,
        .gap = 8,

    });

    for (0..lib.prefs.theme_count) |index| {

        const selected = @intFromEnum(lib.prefs.active_theme) == index;
        const theme_id: lib.prefs.ThemeId = @enumFromInt(@as(u8, @intCast(index)));
        const name = lib.prefs.theme_names[index];

        const item = page.box(row, .{

            .id = swatch_id_base + @as(u32, @intCast(index)),
            .direction = .column,
            .width = .{ .px = theme_col_w },
            .height = .{ .px = swatch_size + 34 },
            .padding = ui.Edge.symmetric(6, 6),
            .align_cross = .center,
            .gap = 6,
            .hover_background = ui.theme.hover,
            .radius = 6,

        });

        _ = page.box(item, .{

            .width = .{ .px = swatch_size },
            .height = .{ .px = swatch_size },
            .background = swatch_color(theme_id),
            .border = if (selected) ui.theme.accent else ui.theme.border,
            .border_width = if (selected) 2 else 1,
            .radius = 6,

        });

        _ = page.label(item, name, .{

            .width = .{ .px = theme_col_w - 12 },
            .height = .{ .px = 16 },
            .size = 11,
            .color = if (selected) ui.theme.text else ui.theme.text_faint,
            .center_text = true,

        });

    }

}

fn paint_temp_section(parent: i16) void {

    const section = page.box(parent, .{

        .direction = .column,
        .gap = 14,

    });

    _ = page.label(section, "Temperature unit", .{

        .size = 14,
        .color = ui.theme.text,

    });

    const row = page.box(section, .{

        .direction = .row,
        .gap = 8,

    });

    paint_unit_button(row, unit_celsius_id, "Celsius", lib.prefs.temp_unit == .celsius);
    paint_unit_button(row, unit_fahrenheit_id, "Fahrenheit", lib.prefs.temp_unit == .fahrenheit);

}

fn paint_unit_button(parent: i16, id: u32, label: []const u8, selected: bool) void {

    paint_choice_button(parent, id, label, selected);

}

fn paint_choice_button(parent: i16, id: u32, label: []const u8, selected: bool) void {

    const item = page.box(parent, .{

        .id = id,
        .direction = .row,
        .width = .{ .px = unit_btn_w },
        .height = .{ .px = unit_btn_h },
        .padding = ui.Edge.symmetric(10, 8),
        .align_main = .center,
        .align_cross = .center,
        .background = if (selected) ui.theme.accent_dim else ui.theme.surface,
        .hover_background = ui.theme.hover,
        .border = if (selected) ui.theme.accent else ui.theme.border,
        .border_width = 1,
        .radius = 6,

    });

    _ = page.label(item, label, .{

        .size = 13,
        .color = if (selected) ui.theme.text else ui.theme.text_dim,
        .center_text = true,

    });

}

fn update_cursor(x: i32, y: i32) void {

    if (page.pointer_move(x, y)) paint();

    const hit = page.hit(x, y);

    if (hit >= swatch_id_base and hit < swatch_id_base + lib.prefs.theme_count) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    if (hit == unit_celsius_id or hit == unit_fahrenheit_id) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    if (hit >= quartz_id_base and hit < quartz_id_base + lib.prefs.quartz_level_count) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    lib.cursor.set(&connection, .pointer);

}

fn swatch_color(id: lib.prefs.ThemeId) gfx.Color {

    return switch (id) {

        .mono => gfx.rgb(120, 120, 120),
        .ocean => gfx.rgb(80, 150, 230),
        .forest => gfx.rgb(80, 180, 100),
        .sunset => gfx.rgb(230, 140, 70),
        .grape => gfx.rgb(160, 110, 220),

    };

}
