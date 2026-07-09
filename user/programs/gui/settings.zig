// Settings: desktop preferences for color theme. Changes apply immediately and persist to disk.

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
const swatch_id_base: u32 = 100;

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

    const hit = page.hit(x, y);

    if (hit < swatch_id_base or hit >= swatch_id_base + lib.prefs.theme_count) return;

    const col = hit - swatch_id_base;

    lib.prefs.apply_theme(@enumFromInt(@as(u8, @intCast(col))));
    lib.prefs.save();
    lib.prefs.broadcast_change(&connection);
    paint();

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    page.begin(width, height, .{

        .direction = .column,
        .width = .{ .px = width },
        .height = .{ .px = height },
        .padding = ui.Edge.all(pad),
        .gap = 18,
        .background = ui.theme.window_bg,

    });

    _ = page.label(ui.Page.root, "Settings", .{

        .size = 18,
        .color = ui.theme.text,

    });

    const content = page.box(ui.Page.root, .{

        .direction = .column,
        .gap = 14,

    });

    _ = page.label(content, "Color theme", .{

        .size = 14,
        .color = ui.theme.text,

    });

    const row = page.box(content, .{

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

    page.end();
    page.paint(surface);

    window.present_all() catch {};

}

fn update_cursor(x: i32, y: i32) void {

    if (page.pointer_move(x, y)) paint();

    const hit = page.hit(x, y);

    if (hit >= swatch_id_base and hit < swatch_id_base + lib.prefs.theme_count) {

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
