// Clipboard: the Super+V history popup.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const clipboard = lib.clipboard;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Clipboard",
    .description = "Recent clipboard items.",
    .icon = "file",
    .category = "Accessories",
};

comptime {

    _ = lib.start;

}

const popup_width: i32 = 300;
const top_pad: i32 = 14;
const header_height: i32 = 28;
const content_gap: i32 = 10;
const bottom_pad: i32 = 8;
const row_height: i32 = 40;
const row_gap: i32 = 6;
const pad_left: i32 = 8;
const pad_right: i32 = 12;
const corner: i32 = 8;
const row_radius: i32 = 8;
const clear_h: i32 = 24;
const clear_w: i32 = 52;
const delete_size: i32 = 26;
const max_visible_rows: usize = 5;

const slide_distance: i32 = 20;
const slide_duration_ms: u64 = 150;

const clear_id: u32 = 1;
const row_id_base: u32 = 100;
const delete_id_base: u32 = 300;

const key_esc: u16 = 1;
const key_enter: u16 = 28;
const key_up: u16 = 103;
const key_down: u16 = 108;

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var history: clipboard.History = .{};
var regions = ui.HitRegions{};

var scroll_row: usize = 0;
var selected: ?usize = null;

var keyboard = lib.keymap.Keyboard{};
var closing = false;

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

    clipboard.load(&history);

    window = try connection.create_window(@intCast(popup_width), @intCast(popup_height()), proto.window.flag_undecorated | proto.window.flag_backdrop, "Clipboard");

    reveal();

    while (!closing) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close, events.kind_window_blur => closing = true,

            events.kind_key_down => key_down_event(event.code),

            events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

            events.kind_button_down => {

                if (event.code == events.button_left) press(event.x, event.y);

            },

            events.kind_pointer_move => {

                if (regions.pointer_move(event.x, event.y)) paint();

                lib.cursor.set(&connection, if (regions.hovered_id() != 0) .clicker else .pointer);

            },

            events.kind_scroll => {

                if (wheel(event.value)) paint();

            },

            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                paint();

            },

            else => {},

        }

    }

    window.destroy();

}

// Geometry.

fn visible_rows() usize {

    return @min(@max(history.count, 1), max_visible_rows);

}

fn popup_height() i32 {

    const rows: i32 = @intCast(visible_rows());
    const gaps = if (rows > 0) (rows - 1) * row_gap else 0;

    return top_pad + header_height + content_gap + rows * row_height + gaps + bottom_pad;

}

fn max_scroll() usize {

    const shown = @min(history.count, max_visible_rows);

    return if (history.count > shown) history.count - shown else 0;

}

fn row_rect(position: usize) Rect {

    const index: i32 = @intCast(position);

    return .{

        .x = pad_left,
        .y = top_pad + header_height + content_gap + index * (row_height + row_gap),

        .w = popup_width - pad_left - pad_right,
        .h = row_height,

    };

}

fn clear_rect() Rect {

    return .{

        .x = popup_width - pad_right - clear_w,
        .y = top_pad + @divTrunc(header_height - clear_h, 2),
        .w = clear_w,
        .h = clear_h,

    };

}

fn delete_rect(row: Rect) Rect {

    return .{

        .x = row.x + row.w - 10 - delete_size,
        .y = row.y + @divTrunc(row.h - delete_size, 2),
        .w = delete_size,
        .h = delete_size,

    };

}

/// Open at the caret of the window that just lost focus, clamped onto the screen, then slide up.
fn reveal() void {

    const screen = lib.wm.screen_info(&connection) catch lib.wm.Screen{ .width = 800, .height = 600 };
    const anchor = lib.wm.caret_anchor(&connection, window.id) catch lib.prefs.WindowGeom{};

    const height = popup_height();

    // Prefer sitting just below the caret; flip above it when the bottom of the screen is close.
    var x = anchor.x - 8;
    var y = anchor.y + @as(i32, @intCast(anchor.height)) + 6;

    if (y + height > @as(i32, @intCast(screen.height))) y = anchor.y - height - 6;

    x = std.math.clamp(x, 8, @max(8, @as(i32, @intCast(screen.width)) - popup_width - 8));
    y = std.math.clamp(y, 8, @max(8, @as(i32, @intCast(screen.height)) - height - 8));

    lib.wm.move_window(&connection, window.id, x, y + slide_distance) catch {};

    paint();

    const start = lib.time.now_ms();

    while (true) {

        const progress = lib.anim.ease_out(lib.anim.progress(lib.time.now_ms() -% start, slide_duration_ms));

        lib.wm.move_window(&connection, window.id, x, y + lib.anim.lerp(slide_distance, 0, progress)) catch {};

        if (progress >= lib.anim.unit) break;

        lib.time.sleep_ms(8);

    }

    lib.wm.move_window(&connection, window.id, x, y) catch {};

}

fn wheel(delta: i64) bool {

    const before = scroll_row;

    scroll_row = @intCast(scroll_model().wheel(delta, 1));

    return scroll_row != before;

}

fn scroll_model() ui.Scroll {

    return .{

        .offset = @intCast(scroll_row),
        .content = @intCast(history.count),
        .viewport = @intCast(@min(history.count, max_visible_rows)),

    };

}

fn clamp_scroll() void {

    if (scroll_row > max_scroll()) scroll_row = max_scroll();

}

// Interaction.

fn press(x: i32, y: i32) void {

    const id = regions.hit(x, y);

    if (id == clear_id) {

        clear_all();
        return;

    }

    if (id >= delete_id_base) {

        remove_entry(id - delete_id_base);
        return;

    }

    if (id >= row_id_base) {

        apply_entry(id - row_id_base);
        return;

    }

}

fn key_down_event(code: u16) void {

    if (keyboard.modifier(events.kind_key_down, code)) return;

    if (code == key_esc) {

        closing = true;
        return;

    }

    if (code == key_enter) {

        if (selected) |index| apply_entry(index);
        return;

    }

    if (code == key_up) {

        if (history.count == 0) return;

        if (selected) |index| {

            if (index == 0) return;

            selected = index - 1;

        } else {

            selected = history.count - 1;

        }

        follow_selection();
        paint();

        return;

    }

    if (code == key_down) {

        if (history.count == 0) return;

        if (selected) |index| {

            if (index + 1 >= history.count) return;

            selected = index + 1;

        } else {

            selected = 0;

        }

        follow_selection();
        paint();

        return;

    }

}

fn follow_selection() void {

    const index = selected orelse return;
    const shown = @min(history.count, max_visible_rows);

    if (index < scroll_row) scroll_row = index;
    if (shown > 0 and index >= scroll_row + shown) scroll_row = index - shown + 1;

    clamp_scroll();

}

/// Make `index` the newest entry and hand a paste back to the window this popup displaced.
fn apply_entry(index: usize) void {

    if (index >= history.count) return;

    var text: [clipboard.max_entry]u8 = undefined;
    const entry = history.entry(index);
    const length = entry.len;

    @memcpy(text[0..length], entry);

    history.prepend(text[0..length]);
    clipboard.store(&history);

    lib.wm.paste_previous(&connection, window.id);

    closing = true;

}

fn remove_entry(index: usize) void {

    if (index >= history.count) return;

    history.remove(index);
    clipboard.store(&history);

    if (selected) |sel| {

        if (sel >= history.count) selected = if (history.count > 0) history.count - 1 else null;

    }

    clamp_scroll();
    resize_to_content();
    paint();

}

fn clear_all() void {

    history.clear();
    clipboard.store(&history);

    scroll_row = 0;
    selected = null;

    resize_to_content();
    paint();

}

fn resize_to_content() void {

    const height = popup_height();

    if (height == @as(i32, @intCast(window.surface.height))) return;

    window.resize(@intCast(popup_width), @intCast(height)) catch {};

}

// Painting.

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);
    const bounds = Rect{ .x = 0, .y = 0, .w = width, .h = height };

    regions.reset();

    surface.fill(lib.draw.transparent);
    ui.stroke_round_rect(surface, bounds, corner, 1, ui.theme.border);

    paint_header(surface);

    if (history.count == 0) {

        ui.widgets.label_in(surface, &font, .{

            .x = pad_left,
            .y = top_pad + header_height + content_gap,
            .w = width - pad_left - pad_right,
            .h = height - top_pad - header_height - content_gap - bottom_pad,

        }, "Nothing copied yet", 13, ui.theme.text_faint);

        window.present_all() catch {};

        return;

    }

    const shown = @min(history.count - scroll_row, max_visible_rows);

    for (0..shown) |position| {

        paint_row(surface, position, scroll_row + position);

    }

    window.present_all() catch {};

}

fn paint_header(surface: *const gfx.Surface) void {

    const title_y = top_pad + @divTrunc(header_height - font.line_height(13), 2);

    font.draw(surface, pad_left * 2, title_y, 13, "Clipboard", ui.theme.text_dim);

    if (history.count == 0) return;

    const rect = clear_rect();

    regions.add(clear_id, rect);
    paint_clear(surface, rect, regions.hovered(clear_id));

}

fn paint_clear(surface: *const gfx.Surface, rect: Rect, hovered: bool) void {

    ui.widgets.button(surface, &font, rect, "Clear", .{

        .hovered = hovered,
        .outlined = true,

    }, .{

        .size = 11,
        .radius = 6,
        .idle = ui.theme.surface_alt,
        .color = ui.theme.text_dim,

    });

}

fn paint_row(surface: *const gfx.Surface, position: usize, index: usize) void {

    const rect = row_rect(position);
    const row_id = row_id_base + @as(u32, @intCast(index));
    const delete_id = delete_id_base + @as(u32, @intCast(index));

    // Stay active while the pointer is over the delete chip too.
    const active = (selected != null and selected.? == index) or regions.hovered(row_id) or regions.hovered(delete_id);

    regions.add(row_id, rect);

    const fill = if (active) ui.theme.surface else lib.draw.transparent;

    ui.fill_round_rect(surface, rect, row_radius, fill);

    paint_preview(surface, rect, index, active);

    if (active) paint_delete(surface, rect, index);

}

fn paint_preview(surface: *const gfx.Surface, rect: Rect, index: usize, show_delete: bool) void {

    const entry = history.entry(index);

    var preview: [96]u8 = undefined;
    const flattened = flatten(entry, &preview);

    const reserve: i32 = if (show_delete) 48 else 20;
    const text_rect = Rect{ .x = rect.x + 12, .y = rect.y, .w = rect.w - reserve, .h = rect.h };
    const clipped = surface.clipped(text_rect);
    const visible = ui.truncate(&font, flattened, 13, text_rect.w);
    const text_y = text_rect.y + @divTrunc(text_rect.h - font.line_height(13), 2);

    font.draw(&clipped, text_rect.x, text_y, 13, visible, ui.theme.text);

}

fn paint_delete(surface: *const gfx.Surface, rect: Rect, index: usize) void {

    const hit = delete_rect(rect);
    const delete_id = delete_id_base + @as(u32, @intCast(index));
    const hovered = regions.hovered(delete_id);

    regions.add(delete_id, hit);

    const icon: i32 = 14;
    const icon_rect = Rect{

        .x = hit.x + @divTrunc(hit.w - icon, 2),
        .y = hit.y + @divTrunc(hit.h - icon, 2),
        .w = icon,
        .h = icon,

    };

    const tint = if (hovered) ui.theme.text else ui.theme.text_dim;

    lib.draw.vector.icon_in(surface, icon_rect, lib.icons.x, tint);

}

/// One-line preview: control bytes become spaces so a multi-line entry still reads as a row.
fn flatten(text: []const u8, out: []u8) []const u8 {

    var length: usize = 0;
    var space = false;

    for (text) |byte| {

        if (length >= out.len) break;

        if (byte < 0x20 or byte >= 0x7f) {

            if (space or length == 0) continue;

            out[length] = ' ';
            length += 1;
            space = true;

            continue;

        }

        out[length] = byte;
        length += 1;
        space = false;

    }

    while (length > 0 and out[length - 1] == ' ') length -= 1;

    return out[0..length];

}
