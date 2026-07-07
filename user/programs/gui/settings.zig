// Settings: desktop preferences for color theme. Changes apply immediately and persist to disk.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Settings",
    .description = "Color theme",
    .icon = "settings",
};

comptime {

    _ = lib.start;

}

const pad: i32 = 24;
const swatch_size: i32 = 36;
const theme_col_w: i32 = 76;

var font: lib.ttf.Face = undefined;

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
    window = try connection.create_window(520, 220, 0, "Settings");

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

            else => {},

        }

    }

}

fn click(x: i32, y: i32) void {

    const theme_y = pad + 36;
    const swatch_y = theme_y + 28;

    const label_h = 18;
    const theme_row_h = swatch_size + 6 + label_h;

    if (y < swatch_y or y >= swatch_y + theme_row_h) return;

    const col = @divTrunc(x - pad, theme_col_w);

    if (col < 0 or col >= @as(i32, @intCast(lib.prefs.theme_count))) return;

    lib.prefs.apply_theme(@enumFromInt(@as(u8, @intCast(col))));
    lib.prefs.save();
    lib.prefs.broadcast_change(&connection);
    paint();

}

fn paint() void {

    const surface = &window.surface;

    surface.fill(ui.theme.window_bg);

    ui.text(surface, &font, pad, pad, 18, "Settings", ui.theme.text);

    const theme_y = pad + 36;

    ui.label(surface, &font, pad, theme_y, 14, "Color theme");

    const swatch_y = theme_y + 28;

    const col_w = theme_col_w;
    const swatch = swatch_size;

    for (0..lib.prefs.theme_count) |index| {

        const col_x = pad + @as(i32, @intCast(index)) * col_w;
        const rect = Rect{ .x = col_x + @divTrunc(col_w - swatch, 2), .y = swatch_y, .w = swatch, .h = swatch };

        const selected = @intFromEnum(lib.prefs.active_theme) == index;

        const theme_id: lib.prefs.ThemeId = @enumFromInt(@as(u8, @intCast(index)));

        surface.fill_rect(rect, swatch_color(theme_id));

        if (selected) surface.stroke_rect(rect, 2, ui.theme.accent);

        const name = lib.prefs.theme_names[index];
        const label_rect = Rect{ .x = col_x, .y = swatch_y + swatch + 6, .w = col_w, .h = 16 };

        ui.text_center(surface, &font, label_rect, 11, name, if (selected) ui.theme.text else ui.theme.text_faint);

    }

    window.present_all() catch {};

}

fn update_cursor(x: i32, y: i32) void {

    const theme_y = pad + 36;
    const swatch_y = theme_y + 28;
    const label_h = 18;
    const theme_row_h = swatch_size + 6 + label_h;

    if (y >= swatch_y and y < swatch_y + theme_row_h) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    _ = x;
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