// Theme, temperature unit, and file-type open handlers; timezone comes from Metrics at boot.

const std = @import("std");

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
const handler_row_h: i32 = 36;
const dropdown_w: i32 = 140;
const swatch_id_base: u32 = 100;
const unit_celsius_id: u32 = 200;
const unit_fahrenheit_id: u32 = 201;
const handler_id_base: u32 = 300;

const choice_labels = [_][]const u8{

    "Images",
    "Notepad",
    "Geode",
    "Off",

};

const dropdown_rows = [_]ui.Menu.Row{

    .{ .item = "Images" },
    .{ .item = "Notepad" },
    .{ .item = "Geode" },
    .{ .item = "Off" },

};

var font: lib.draw.text.Face = undefined;
var page: ui.Page = .{ .font = &font };

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var dropdown_menu = ui.Menu{ .width = dropdown_w };
var dropdown_for: ?usize = null;

var ext_labels: [lib.handler.max_handlers][16]u8 = undefined;
var ext_label_lens: [lib.handler.max_handlers]usize = .{0} ** lib.handler.max_handlers;
var choice_labels_buf: [lib.handler.max_handlers][24]u8 = undefined;
var choice_label_lens: [lib.handler.max_handlers]usize = .{0} ** lib.handler.max_handlers;

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    lib.prefs.refresh();

    if (args.len > 0) lib.wm.bind_program(args[0]);

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    lib.handler.ensure();

    connection = try lib.desktop.connect(cap.memory);
    window = try lib.wm.open_main(&connection, 520, 560, "Settings");

    paint();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                lib.wm.close_main(&connection, &window);
                return;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                close_dropdown();
                paint();

            },

            events.kind_button_down => {

                if (event.code == events.button_left) click(event.x, event.y);

            },

            events.kind_pointer_move => update_cursor(event.x, event.y),

            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                close_dropdown();
                paint();

            },

            else => {},

        }

    }

}

fn click(x: i32, y: i32) void {

    if (dropdown_menu.open) {

        if (dropdown_menu.hit(x, y)) |row| {

            if (dropdown_for) |index| apply_choice(index, row);

            close_dropdown();
            paint();

            return;

        }

        const prior = dropdown_for;

        close_dropdown();

        // Same trigger again just dismisses; other hits are handled below.
        const hit = page.hit(x, y);

        if (prior) |index| {

            if (hit == handler_id_base + index) {

                paint();
                return;

            }

        }

        handle_page_hit(hit);
        paint();

        return;

    }

    handle_page_hit(page.hit(x, y));
    paint();

}

fn handle_page_hit(hit: u32) void {

    if (hit >= swatch_id_base and hit < swatch_id_base + lib.prefs.theme_count) {

        const col = hit - swatch_id_base;

        lib.prefs.apply_theme(@enumFromInt(@as(u8, @intCast(col))));
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);

        return;

    }

    if (hit == unit_celsius_id or hit == unit_fahrenheit_id) {

        const next: lib.prefs.TempUnit = if (hit == unit_fahrenheit_id) .fahrenheit else .celsius;

        if (lib.prefs.temp_unit == next) return;

        lib.prefs.temp_unit = next;
        lib.prefs.save();
        lib.prefs.broadcast_change(&connection);

        return;

    }

    if (hit >= handler_id_base and hit < handler_id_base + lib.handler.count()) {

        open_dropdown(hit - handler_id_base);

    }

}

fn apply_choice(index: usize, row: usize) void {

    const slot = lib.handler.at(index) orelse return;
    const ext = slot.extension();

    const program: []const u8 = switch (row) {

        0 => "viewer",
        1 => "notepad",
        2 => "audio-gui",
        else => "",

    };

    _ = lib.handler.set_program(ext, program);
    lib.prefs.save();
    lib.prefs.broadcast_change(&connection);

}

fn open_dropdown(index: usize) void {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const id = handler_id_base + @as(u32, @intCast(index));
    const anchor = page.rect_of(id) orelse return;

    dropdown_for = index;
    dropdown_menu.open_at(dropdown_rows[0..], anchor.x, anchor.y + anchor.h + 2, width, height);

    // Align the menu with the right edge of the trigger.
    dropdown_menu.x = @max(0, @min(anchor.x + anchor.w - dropdown_menu.width, width - dropdown_menu.width));

    if (dropdown_menu.y + dropdown_menu.bounds().h > height) {

        dropdown_menu.y = @max(0, anchor.y - dropdown_menu.bounds().h - 2);

    }

}

fn close_dropdown() void {

    dropdown_menu.close();
    dropdown_for = null;

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    surface.fill(ui.theme.window_bg);

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
    paint_temp_section(content);
    paint_handler_section(content);

    page.end();
    page.paint(surface);

    paint_dropdown_chevrons(surface);

    if (dropdown_menu.open) dropdown_menu.paint(surface, &font);

    window.present_all() catch {};

}

/// Pixel chevrons — Inter has no reliable ▾ glyph (see Chisel).
fn paint_dropdown_chevrons(surface: *const gfx.Surface) void {

    const count = lib.handler.count();

    for (0..count) |index| {

        const id = handler_id_base + @as(u32, @intCast(index));
        const rect = page.rect_of(id) orelse continue;
        const open = dropdown_for != null and dropdown_for.? == index;
        const cx = rect.x + rect.w - 16;
        const cy = rect.y + @divTrunc(rect.h, 2);

        if (open) draw_chevron_up(surface, cx, cy, ui.theme.text_dim) else draw_chevron_down(surface, cx, cy, ui.theme.text_dim);

    }

}

fn draw_chevron_down(surface: *const gfx.Surface, cx: i32, cy: i32, color: gfx.Color) void {

    surface.put_pixel(cx - 3, cy - 1, color);
    surface.put_pixel(cx - 2, cy - 1, color);
    surface.put_pixel(cx + 2, cy - 1, color);
    surface.put_pixel(cx + 3, cy - 1, color);

    surface.put_pixel(cx - 2, cy, color);
    surface.put_pixel(cx - 1, cy, color);
    surface.put_pixel(cx + 1, cy, color);
    surface.put_pixel(cx + 2, cy, color);

    surface.put_pixel(cx - 1, cy + 1, color);
    surface.put_pixel(cx, cy + 1, color);
    surface.put_pixel(cx + 1, cy + 1, color);

    surface.put_pixel(cx, cy + 2, color);

}

fn draw_chevron_up(surface: *const gfx.Surface, cx: i32, cy: i32, color: gfx.Color) void {

    surface.put_pixel(cx, cy - 2, color);

    surface.put_pixel(cx - 1, cy - 1, color);
    surface.put_pixel(cx, cy - 1, color);
    surface.put_pixel(cx + 1, cy - 1, color);

    surface.put_pixel(cx - 2, cy, color);
    surface.put_pixel(cx - 1, cy, color);
    surface.put_pixel(cx + 1, cy, color);
    surface.put_pixel(cx + 2, cy, color);

    surface.put_pixel(cx - 3, cy + 1, color);
    surface.put_pixel(cx - 2, cy + 1, color);
    surface.put_pixel(cx + 2, cy + 1, color);
    surface.put_pixel(cx + 3, cy + 1, color);

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

    paint_choice_button(row, unit_celsius_id, "Celsius", lib.prefs.temp_unit == .celsius);
    paint_choice_button(row, unit_fahrenheit_id, "Fahrenheit", lib.prefs.temp_unit == .fahrenheit);

}

fn paint_handler_section(parent: i16) void {

    const section = page.box(parent, .{

        .direction = .column,
        .gap = 0,

    });

    _ = page.label(section, "File types", .{

        .size = 14,
        .color = ui.theme.text,

    });

    // Spacer under the section title before the list.
    _ = page.box(section, .{

        .width = .{ .grow = 1 },
        .height = .{ .px = 10 },

    });

    const count = lib.handler.count();

    for (0..count) |index| {

        const slot = lib.handler.at(index) orelse continue;
        const open = dropdown_for != null and dropdown_for.? == index;

        const ext_text = std.fmt.bufPrint(&ext_labels[index], ".{s}", .{slot.extension()}) catch continue;

        ext_label_lens[index] = ext_text.len;

        const choice = choice_label(slot);
        const choice_text = std.fmt.bufPrint(&choice_labels_buf[index], "{s}", .{choice}) catch continue;

        choice_label_lens[index] = choice_text.len;

        const row = page.box(section, .{

            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .px = handler_row_h + 8 },
            .padding = ui.Edge.symmetric(0, 4),
            .align_main = .between,
            .align_cross = .center,
            .gap = 12,

        });

        _ = page.label(row, ext_labels[index][0..ext_label_lens[index]], .{

            .size = 13,
            .color = ui.theme.text,

        });

        const trigger = page.box(row, .{

            .id = handler_id_base + @as(u32, @intCast(index)),
            .direction = .row,
            .width = .{ .px = dropdown_w },
            .height = .{ .px = handler_row_h },
            .padding = ui.Edge{ .top = 8, .right = 28, .bottom = 8, .left = 12 },
            .align_main = .start,
            .align_cross = .center,
            .background = if (open) ui.theme.active else ui.theme.surface,
            .hover_background = ui.theme.hover,
            .border = if (open) ui.theme.accent else ui.theme.border,
            .border_width = 1,
            .radius = 6,

        });

        _ = page.label(trigger, choice_labels_buf[index][0..choice_label_lens[index]], .{

            .size = 13,
            .color = ui.theme.text,

        });

    }

}

fn choice_label(slot: *const lib.handler.Slot) []const u8 {

    if (!slot.enabled or slot.program_len == 0) return choice_labels[3];

    if (std.mem.eql(u8, slot.app(), "viewer")) return choice_labels[0];
    if (std.mem.eql(u8, slot.app(), "notepad")) return choice_labels[1];
    if (std.mem.eql(u8, slot.app(), "audio-gui")) return choice_labels[2];

    return slot.app();

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

    var dirty = page.pointer_move(x, y);

    if (dropdown_menu.open and dropdown_menu.pointer_move(x, y)) dirty = true;

    if (dirty) paint();

    if (dropdown_menu.open and dropdown_menu.hit(x, y) != null) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    const hit = page.hit(x, y);

    if (hit >= swatch_id_base and hit < swatch_id_base + lib.prefs.theme_count) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    if (hit == unit_celsius_id or hit == unit_fahrenheit_id) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    if (hit >= handler_id_base and hit < handler_id_base + lib.handler.count()) {

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
