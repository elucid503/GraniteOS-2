// Settings: desktop preferences for color theme and display scale. Changes apply immediately and persist to disk.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Settings",
    .description = "Theme and display scale",
    .icon = "settings",
};

comptime {

    _ = lib.start;

}

const pad: i32 = 24;
const section_gap: i32 = 32;
const swatch_size: i32 = 36;
const theme_col_w: i32 = 76;

var font: lib.ttf.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var pointer_x: i32 = -1;
var pointer_y: i32 = -1;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(520, 360, 0, "Settings");

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

            events.kind_pointer_move => {

                pointer_x = event.x;
                pointer_y = event.y;
                update_cursor(event.x, event.y);

            },

            else => {},

        }

    }

}

fn click(x: i32, y: i32) void {

    const theme_y = pad + lib.prefs.scale_px(36);
    const swatch_y = theme_y + lib.prefs.scale_px(28);

    const label_h = lib.prefs.scale_px(18);
    const theme_row_h = lib.prefs.scale_px(swatch_size) + lib.prefs.scale_px(6) + label_h;

    if (y >= swatch_y and y < swatch_y + theme_row_h) {

        const col = @divTrunc(x - pad, lib.prefs.scale_px(theme_col_w));

        if (col >= 0 and col < @as(i32, @intCast(lib.prefs.theme_count))) {

            lib.prefs.apply_theme(@enumFromInt(@as(u8, @intCast(col))));
            lib.prefs.save();
            lib.prefs.broadcast_change(&connection);
            paint();

        }

        return;

    }

    const scale_y = swatch_y + theme_row_h + section_gap;
    const button_y = scale_y + lib.prefs.scale_px(56);

    const minus = Rect{ .x = pad, .y = button_y, .w = lib.prefs.scale_px(48), .h = lib.prefs.scale_px(32) };
    const plus = Rect{ .x = pad + lib.prefs.scale_px(56), .y = button_y, .w = lib.prefs.scale_px(48), .h = lib.prefs.scale_px(32) };

    if (minus.contains(x, y)) {

        lib.prefs.set_scale(lib.prefs.scale_percent - 25);
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);
        paint();

        return;

    }

    if (plus.contains(x, y)) {

        lib.prefs.set_scale(lib.prefs.scale_percent + 25);
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);
        paint();

    }

}

fn paint() void {

    const surface = &window.surface;

    surface.fill(ui.theme.window_bg);

    ui.text(surface, &font, pad, pad, lib.prefs.scale_u(18), "Settings", ui.theme.text);

    const theme_y = pad + lib.prefs.scale_px(36);

    ui.label(surface, &font, pad, theme_y, lib.prefs.scale_u(14), "Color theme");

    const swatch_y = theme_y + lib.prefs.scale_px(28);

    const col_w = lib.prefs.scale_px(theme_col_w);
    const swatch = lib.prefs.scale_px(swatch_size);

    for (0..lib.prefs.theme_count) |index| {

        const col_x = pad + @as(i32, @intCast(index)) * col_w;
        const rect = Rect{ .x = col_x + @divTrunc(col_w - swatch, 2), .y = swatch_y, .w = swatch, .h = swatch };

        const selected = @intFromEnum(lib.prefs.active_theme) == index;

        const theme_id: lib.prefs.ThemeId = @enumFromInt(@as(u8, @intCast(index)));

        surface.fill_rect(rect, swatch_color(theme_id));

        if (selected) surface.stroke_rect(rect, 2, ui.theme.accent);

        const name = lib.prefs.theme_names[index];
        const label_rect = Rect{ .x = col_x, .y = swatch_y + swatch + lib.prefs.scale_px(6), .w = col_w, .h = lib.prefs.scale_px(16) };

        ui.text_center(surface, &font, label_rect, lib.prefs.scale_u(11), name, if (selected) ui.theme.text else ui.theme.text_faint);

    }

    const label_h = lib.prefs.scale_px(18);
    const theme_row_h = swatch + lib.prefs.scale_px(6) + label_h;

    const scale_y = swatch_y + theme_row_h + section_gap + lib.prefs.scale_px(20);

    ui.label(surface, &font, pad, scale_y, lib.prefs.scale_u(14), "Display scale");

    var buffer: [16]u8 = undefined;
    const scale_text = std.fmt.bufPrint(&buffer, "{d}%", .{lib.prefs.scale_percent}) catch "";

    ui.text(surface, &font, pad, scale_y + lib.prefs.scale_px(24), lib.prefs.scale_u(22), scale_text, ui.theme.accent);

    const button_y = scale_y + lib.prefs.scale_px(56);
    const minus = Rect{ .x = pad, .y = button_y, .w = lib.prefs.scale_px(48), .h = lib.prefs.scale_px(32) };
    const plus = Rect{ .x = pad + lib.prefs.scale_px(56), .y = button_y, .w = lib.prefs.scale_px(48), .h = lib.prefs.scale_px(32) };

    const minus_hover = minus.contains(pointer_x, pointer_y);
    const plus_hover = plus.contains(pointer_x, pointer_y);

    ui.button(surface, &font, minus, "-", lib.prefs.scale_u(16), if (minus_hover) .hover else .normal);
    ui.button(surface, &font, plus, "+", lib.prefs.scale_u(16), if (plus_hover) .hover else .normal);

    window.present_all() catch {};

}

fn update_cursor(x: i32, y: i32) void {

    const theme_y = pad + lib.prefs.scale_px(36);
    const swatch_y = theme_y + lib.prefs.scale_px(28);
    const label_h = lib.prefs.scale_px(18);
    const theme_row_h = lib.prefs.scale_px(swatch_size) + lib.prefs.scale_px(6) + label_h;
    const scale_y = swatch_y + theme_row_h + section_gap + lib.prefs.scale_px(20);
    const button_y = scale_y + lib.prefs.scale_px(56);

    const minus = Rect{ .x = pad, .y = button_y, .w = lib.prefs.scale_px(48), .h = lib.prefs.scale_px(32) };
    const plus = Rect{ .x = pad + lib.prefs.scale_px(56), .y = button_y, .w = lib.prefs.scale_px(48), .h = lib.prefs.scale_px(32) };

    if (y >= swatch_y and y < swatch_y + theme_row_h) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    if (minus.contains(x, y) or plus.contains(x, y)) {

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