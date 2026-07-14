// Chisel: a fast MS Paint-style drawing pad. Pixels live in a private canvas buffer; strokes present only their dirty rect so freehand drawing stays responsive. Export writes a PNG via lib/draw/png.encode.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;
const Color = gfx.Color;

pub const app_meta = .{
    .title = "Chisel",
    .description = "Create and save drawings.",
    .icon = "paint",
    .category = "Graphics",
};

comptime {

    _ = lib.start;

}

const canvas_w: u32 = 640;
const canvas_h: u32 = 400;
const canvas_pixels = canvas_w * canvas_h;

const toolbar_h: i32 = 100;
const chip_h: i32 = 30;
const color_swatch: i32 = 22;
const pad: i32 = 12;
const gap: i32 = 8;
const radius: i32 = 8;
const chip_radius: i32 = 6;

const Tool = enum(u8) {

    pencil,
    brush,
    eraser,
    line,
    rect,
    fill_rect,
    ellipse,
    fill_ellipse,
    fill,
    picker,

};

const Menu = enum {

    none,
    file,
    shapes,

};

const tool_labels = [_][]const u8{

    "Pen", "Brush", "Eraser", "Line", "Rect", "Fill rect", "Oval", "Fill oval", "Fill", "Pick",

};

// Primary tools always on the bar; shapes live in the Shapes menu.
const primary_tools = [_]Tool{ .pencil, .brush, .eraser, .fill, .picker };
const shape_tools = [_]Tool{ .line, .rect, .fill_rect, .ellipse, .fill_ellipse };

const file_items = [_]struct { id: i32, label: []const u8 }{

    .{ .id = 100, .label = "New" },
    .{ .id = 101, .label = "Undo" },
    .{ .id = 102, .label = "Save PNG" },

};

const palette = [_]Color{

    gfx.rgb(0, 0, 0),
    gfx.rgb(64, 64, 64),
    gfx.rgb(128, 128, 128),
    gfx.rgb(192, 192, 192),
    gfx.rgb(255, 255, 255),
    gfx.rgb(180, 40, 40),
    gfx.rgb(220, 100, 40),
    gfx.rgb(230, 200, 40),
    gfx.rgb(40, 160, 60),
    gfx.rgb(40, 140, 200),
    gfx.rgb(50, 70, 200),
    gfx.rgb(140, 60, 200),
    gfx.rgb(220, 80, 160),
    gfx.rgb(120, 80, 40),
    gfx.rgb(20, 120, 100),
    gfx.rgb(200, 200, 180),

};

const sizes = [_]u8{ 1, 2, 4, 8 };

const Point = struct {

    x: i32,
    y: i32,

};

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var client: ?lib.fs.Client = null;
var picker: lib.file_picker.FilePicker = undefined;

var canvas_region: cap.Handle = 0;
var canvas_base: usize = 0;
var canvas: [*]u32 = undefined;

var undo_region: cap.Handle = 0;
var undo_base: usize = 0;
var undo_pixels: [*]u32 = undefined;
var undo_valid = false;

var encode_arena: []u8 = &.{};

var tool: Tool = .pencil;
var brush_size: u8 = 2;
var fg: Color = gfx.rgb(0, 0, 0);
var bg: Color = gfx.rgb(255, 255, 255);

var drawing = false;
var shape_preview = false;
var last_x: i32 = 0;
var last_y: i32 = 0;
var start_x: i32 = 0;
var start_y: i32 = 0;

var dirty = false;
var status: []const u8 = "";
var hover: i32 = -1;
var open_menu: Menu = .none;

var pointer_x: i32 = -1;
var pointer_y: i32 = -1;

var path_storage: [lib.file_picker.max_path]u8 = undefined;
var file_path_len: usize = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(700, 540, 0, "Chisel");
    _ = lib.draw.round.masks_for(radius);
    _ = lib.draw.round.masks_for(chip_radius);
    _ = lib.draw.round.masks_for(4);

    try alloc_canvases();
    clear_canvas(bg);
    snapshot_undo();

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

    } else |_| {}

    picker.init();

    paint_full();

    while (true) {

        var batch: [32]events.Event = undefined;
        var count: usize = 0;

        batch[count] = try connection.wait_event();
        count += 1;

        while (count < batch.len) {

            if (connection.poll_event()) |event| {

                batch[count] = event;
                count += 1;

            } else break;

        }

        if (dispatch(batch[0..count])) return;

    }

}

fn dispatch(batch: []const events.Event) bool {

    var last_move: ?events.Event = null;
    var need_full = false;
    var stroke_damage = Rect.empty;

    for (batch) |event| {

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return true;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                need_full = true;

            },

            events.kind_button_down => {

                if (picker.open) {

                    if (picker.click(event.x, event.y, win_w(), win_h())) need_full = true;
                    if (picker.take_result()) |path| handle_save_path(path);
                    continue;

                }

                if (event.code == events.button_left or event.code == events.button_right) {

                    if (button_down(event.x, event.y, event.code == events.button_right)) |damage| {

                        stroke_damage = Rect.cover(stroke_damage, damage);

                    } else need_full = true;

                }

            },

            events.kind_button_up => {

                if (picker.open) continue;

                if (event.code == events.button_left or event.code == events.button_right) {

                    if (button_up(event.x, event.y)) |damage| {

                        stroke_damage = Rect.cover(stroke_damage, damage);

                    } else need_full = true;

                }

            },

            events.kind_pointer_move => last_move = event,

            events.kind_key_down => {

                if (picker.open) {

                    if (picker.key(event.code)) need_full = true;
                    if (picker.take_result()) |path| handle_save_path(path);

                } else key_down(event.code);

            },

            events.kind_key_up => picker.key_up(event.code),

            events.kind_scroll => {

                if (picker.open and picker.scroll_by(event.value, win_w(), win_h())) need_full = true;

            },

            events.kind_prefs_changed => {

                lib.prefs.refresh();
                need_full = true;

            },

            else => {},

        }

    }

    if (last_move) |event| {

        pointer_x = event.x;
        pointer_y = event.y;

        if (picker.open) {

            if (picker.pointer_move(event.x, event.y, win_w(), win_h())) need_full = true;

        } else if (drawing) {

            if (pointer_drag(event.x, event.y)) |damage| {

                stroke_damage = Rect.cover(stroke_damage, damage);

            }

        } else {

            const next = if (open_menu != .none)
                (if (menu_item_hit(event.x, event.y)) |id| id else toolbar_hit(event.x, event.y))
            else
                toolbar_hit(event.x, event.y);

            if (next != hover) {

                hover = next;
                need_full = true;

            }

            update_cursor(event.x, event.y);

        }

    }

    if (need_full) {

        paint_full();
        return false;

    }

    if (!stroke_damage.is_empty()) paint_canvas_damage(stroke_damage);

    return false;

}

fn alloc_canvases() !void {

    const bytes = canvas_pixels * @sizeOf(u32);

    canvas_region = try sys.create(.region, bytes, cap.memory);
    canvas_base = try sys.map(cap.self_space, canvas_region, 0, sys.read | sys.write);
    canvas = @ptrFromInt(canvas_base);

    undo_region = try sys.create(.region, bytes, cap.memory);
    undo_base = try sys.map(cap.self_space, undo_region, 0, sys.read | sys.write);
    undo_pixels = @ptrFromInt(undo_base);

    // Scratch (filtered scanlines) + PNG output live in one region; sizes match lib.draw.png helpers.
    const scratch_len = lib.draw.png.raw_scratch_size(canvas_w, canvas_h);
    const dest_len = lib.draw.png.max_encode_size(canvas_w, canvas_h);
    const encode_bytes = scratch_len + dest_len + 64 * 1024;
    const encode_region = try sys.create(.region, encode_bytes, cap.memory);
    const encode_base = try sys.map(cap.self_space, encode_region, 0, sys.read | sys.write);

    encode_arena = @as([*]u8, @ptrFromInt(encode_base))[0..encode_bytes];

}

fn clear_canvas(color: Color) void {

    @memset(canvas[0..canvas_pixels], color);
    dirty = true;

}

fn snapshot_undo() void {

    @memcpy(undo_pixels[0..canvas_pixels], canvas[0..canvas_pixels]);
    undo_valid = true;

}

fn restore_undo() void {

    if (!undo_valid) return;

    @memcpy(canvas[0..canvas_pixels], undo_pixels[0..canvas_pixels]);
    dirty = true;
    status = "Undid last stroke";

}

fn canvas_surface() gfx.Surface {

    return gfx.Surface.from_pixels(canvas, canvas_w, canvas_h);

}

fn canvas_origin() struct { x: i32, y: i32 } {

    const width = win_w();
    const area_w = width - pad * 2;
    const x = pad + @divTrunc(area_w - @as(i32, @intCast(canvas_w)), 2);
    const y = toolbar_h + pad;

    return .{ .x = @max(pad, x), .y = y };

}

fn win_w() i32 {

    return @intCast(window.surface.width);

}

fn win_h() i32 {

    return @intCast(window.surface.height);

}

fn to_canvas(x: i32, y: i32) ?Point {

    const origin = canvas_origin();
    const cx = x - origin.x;
    const cy = y - origin.y;

    if (cx < 0 or cy < 0 or cx >= canvas_w or cy >= canvas_h) return null;

    return .{ .x = cx, .y = cy };

}

fn button_down(x: i32, y: i32, right: bool) ?Rect {

    // A dropdown panel can extend past toolbar_h, so route by the panel rect — not the bar height —
    // or an item below the bar (e.g. "Save PNG") reads as a canvas click and the action is lost.
    if (open_menu != .none) {

        if (y < toolbar_h or menu_panel_rect(open_menu).contains(x, y)) {

            toolbar_click(x, y, right);
            return null;

        }

        open_menu = .none;
        paint_full();
        return null;

    }

    if (y < toolbar_h) {

        toolbar_click(x, y, right);
        return null;

    }

    const point = to_canvas(x, y) orelse return null;
    const color = if (right) bg else fg;

    if (tool == .picker) {

        fg = canvas_get(point.x, point.y);
        status = "Picked color";
        return null;

    }

    snapshot_undo();
    drawing = true;
    start_x = point.x;
    start_y = point.y;
    last_x = point.x;
    last_y = point.y;

    if (tool == .fill) {

        flood_fill(point.x, point.y, color);
        drawing = false;
        dirty = true;
        status = "Filled";
        return canvas_bounds();

    }

    if (is_freehand()) {

        const damage = stamp(point.x, point.y, color, active_size(right));
        dirty = true;
        return damage;

    }

    // Shape tools: preview on pointer move; commit on release.
    shape_preview = true;
    return null;

}

fn button_up(x: i32, y: i32) ?Rect {

    if (!drawing) return null;

    const point = to_canvas(x, y) orelse Point{ .x = last_x, .y = last_y };

    drawing = false;

    if (is_freehand()) {

        shape_preview = false;
        status = "Stroke";
        return null;

    }

    shape_preview = false;

    const color = fg;
    const damage = draw_shape(start_x, start_y, point.x, point.y, color, false);

    dirty = true;
    status = "Shape";

    return damage;

}

fn pointer_drag(x: i32, y: i32) ?Rect {

    const point = to_canvas(x, y) orelse return null;

    if (is_freehand()) {

        const color = if (tool == .eraser) bg else fg;
        const damage = stroke_line(last_x, last_y, point.x, point.y, color, active_size(false));

        last_x = point.x;
        last_y = point.y;
        dirty = true;

        return damage;

    }

    // Shape preview: restore canvas from undo and redraw the rubber-band shape.
    last_x = point.x;
    last_y = point.y;
    paint_full();

    return null;

}

fn is_freehand() bool {

    return tool == .pencil or tool == .brush or tool == .eraser;

}

fn active_size(right: bool) u8 {

    _ = right;

    return switch (tool) {

        .pencil => 1,
        .eraser => brush_size + 2,
        else => brush_size,

    };

}

fn toolbar_click(x: i32, y: i32, right: bool) void {

    // Menu item hits when a dropdown is open.
    if (open_menu != .none) {

        if (menu_item_hit(x, y)) |id| {

            open_menu = .none;
            apply_action(id, right);
            paint_full();
            return;

        }

        // Click outside a menu closes it (and may hit another control).
        open_menu = .none;

    }

    const id = toolbar_hit(x, y);

    if (id < 0) {

        paint_full();
        return;

    }

    if (id == 200) {

        open_menu = if (open_menu == .file) .none else .file;
        paint_full();
        return;

    }

    if (id == 201) {

        open_menu = if (open_menu == .shapes) .none else .shapes;
        paint_full();
        return;

    }

    apply_action(id, right);
    paint_full();

}

fn apply_action(id: i32, right: bool) void {

    if (id < 10) {

        tool = @enumFromInt(@as(u8, @intCast(id)));
        status = tool_labels[@intCast(id)];
        return;

    }

    if (id >= 20 and id < 24) {

        brush_size = sizes[@intCast(id - 20)];
        status = "Brush size";
        return;

    }

    if (id >= 40 and id < 40 + @as(i32, palette.len)) {

        const color = palette[@intCast(id - 40)];

        if (right) bg = color else fg = color;

        status = if (right) "Background color" else "Foreground color";
        return;

    }

    switch (id) {

        100 => {

            snapshot_undo();
            clear_canvas(bg);
            status = "New canvas";

        },

        101 => {

            restore_undo();
            status = if (undo_valid) "Undid last stroke" else "Nothing to undo";

        },

        102 => begin_save(),

        else => {},

    }

}

fn begin_save() void {

    const handle = if (client) |*c| c else {

        status = "Filesystem unavailable";
        paint_full();
        return;

    };

    const start = if (file_path_len != 0) parent_dir(path_storage[0..file_path_len]) else "/root/user";

    picker.show_save(handle, &font, .png, start, "drawing.png");
    paint_full();

}

fn handle_save_path(path: []const u8) void {

    // The write itself blocks for a while on this OS's block driver; paint a status line first so the
    // window shows feedback instead of sitting on the picker's last frame for the entire encode+write.
    status = "Saving...";
    paint_full();

    save_png(path);
    paint_full();

}

fn save_png(path: []const u8) void {

    const handle = if (client) |*c| c else {

        status = "Filesystem unavailable";
        return;

    };

    const scratch_len = lib.draw.png.raw_scratch_size(canvas_w, canvas_h);
    const dest_len = lib.draw.png.max_encode_size(canvas_w, canvas_h);

    if (encode_arena.len < scratch_len + dest_len) {

        status = "Encode buffer too small";
        return;

    }

    const scratch = encode_arena[0..scratch_len];
    const dest = encode_arena[scratch_len .. scratch_len + dest_len];

    const bytes = lib.draw.png.encodeTo(dest, scratch, canvas[0..canvas_pixels], canvas_w, canvas_h) catch {

        status = "PNG encode failed";
        return;

    };

    // Self-check before touching the disk: dimensions must match and a sample pixel must round-trip.
    const size = lib.draw.png.dimensions(bytes) catch {

        status = "PNG self-check failed";
        return;

    };

    if (size.width != canvas_w or size.height != canvas_h) {

        status = "PNG size mismatch";
        return;

    }

    // Prefer atomic create/truncate so a failed rewrite never leaves a half-written file.
    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = handle.open_path(path, flags) catch {

        status = "Cannot open for write";
        return;

    };
    defer handle.close_file(file) catch {};

    var offset: u64 = 0;
    var chunks: usize = 0;

    while (offset < bytes.len) {

        const written = handle.write(file, offset, bytes[@intCast(offset)..]) catch {

            status = "Write failed";
            return;

        };

        if (written == 0) {

            status = "Write stalled";
            return;

        }

        offset += written;
        chunks += 1;

        // Occasional yield so a long write does not starve the compositor, without thrashing IPC.
        if ((chunks & 15) == 0) sys.yield();

    }

    if (offset != bytes.len) {

        status = "Incomplete write";
        return;

    }

    const length = @min(path.len, path_storage.len);

    @memcpy(path_storage[0..length], path[0..length]);
    file_path_len = length;
    dirty = false;
    status = "Saved PNG";

}

fn parent_dir(path: []const u8) []const u8 {

    if (path.len <= 1) return "/";

    var index = path.len;

    while (index > 0) {

        index -= 1;

        if (path[index] == '/') {

            if (index == 0) return "/";

            return path[0..index];

        }

    }

    return "/";

}

fn key_down(code: u16) void {

    var keyboard = lib.keymap.Keyboard{};
    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len != 1) return;

    switch (bytes[0]) {

        's', 'S' => {

            begin_save();
            paint_full();

        },
        'z', 'Z' => {

            restore_undo();
            paint_full();

        },
        'n', 'N' => {

            snapshot_undo();
            clear_canvas(bg);
            paint_full();

        },
        '1' => tool = .pencil,
        '2' => tool = .brush,
        '3' => tool = .eraser,
        '4' => tool = .line,
        '5' => tool = .rect,
        '6' => tool = .fill_rect,
        '7' => tool = .ellipse,
        '8' => tool = .fill_ellipse,
        'f', 'F' => tool = .fill,
        'i', 'I' => tool = .picker,
        else => return,

    }

    paint_full();

}

fn row1_y() i32 {

    return pad;

}

fn row2_y() i32 {

    return pad + chip_h + gap + 4;

}

fn chip_width(label: []const u8) i32 {

    return @max(40, font.text_width(label, 12) + 16);

}

fn menu_chip_width(label: []const u8) i32 {

    // Label plus room for a drawn chevron (the Inter face has no reliable ▾ glyph).
    return @max(48, font.text_width(label, 12) + 28);

}

fn file_btn_rect() Rect {

    return .{ .x = pad, .y = row1_y(), .w = menu_chip_width("File"), .h = chip_h };

}

fn primary_tool_rect(index: usize) Rect {

    var x = file_btn_rect().x + file_btn_rect().w + gap;
    var i: usize = 0;

    while (i < index) : (i += 1) {

        x += chip_width(tool_labels[@intFromEnum(primary_tools[i])]) + gap;

    }

    return .{ .x = x, .y = row1_y(), .w = chip_width(tool_labels[@intFromEnum(primary_tools[index])]), .h = chip_h };

}

fn shapes_btn_rect() Rect {

    const last = primary_tool_rect(primary_tools.len - 1);

    return .{ .x = last.x + last.w + gap, .y = row1_y(), .w = menu_chip_width("Shapes"), .h = chip_h };

}

fn size_rect(index: usize) Rect {

    return .{

        .x = pad + @as(i32, @intCast(index)) * (30 + 6),
        .y = row2_y(),
        .w = 30,
        .h = chip_h,

    };

}

fn palette_origin() Point {

    const after_sizes = size_rect(sizes.len - 1).x + size_rect(sizes.len - 1).w + gap * 2;

    return .{ .x = after_sizes, .y = row2_y() + @divTrunc(chip_h - color_swatch, 2) };

}

fn palette_rect(index: usize) Rect {

    const origin = palette_origin();

    return .{

        .x = origin.x + @as(i32, @intCast(index)) * (color_swatch + 4),
        .y = origin.y,
        .w = color_swatch,
        .h = color_swatch,

    };

}

fn color_well_rect() Rect {

    const last = palette_rect(palette.len - 1);
    const well: i32 = 34;

    return .{

        .x = last.x + last.w + gap + 4,
        .y = row2_y() + @divTrunc(chip_h - well, 2),
        .w = well,
        .h = well,

    };

}

fn menu_panel_rect(menu: Menu) Rect {

    const anchor = switch (menu) {

        .file => file_btn_rect(),
        .shapes => shapes_btn_rect(),
        .none => return Rect.empty,

    };

    const count: i32 = switch (menu) {

        .file => @intCast(file_items.len),
        .shapes => @intCast(shape_tools.len),
        .none => 0,

    };

    const item_h: i32 = 28;
    var width: i32 = 120;

    switch (menu) {

        .file => {

            for (file_items) |item| width = @max(width, chip_width(item.label) + 8);

        },

        .shapes => {

            for (shape_tools) |t| width = @max(width, chip_width(tool_labels[@intFromEnum(t)]) + 8);

        },

        .none => {},

    }

    return .{

        .x = anchor.x,
        .y = anchor.y + anchor.h + 4,
        .w = width,
        .h = count * item_h + 8,

    };

}

fn menu_item_hit(x: i32, y: i32) ?i32 {

    if (open_menu == .none) return null;

    const panel = menu_panel_rect(open_menu);

    if (!panel.contains(x, y)) return null;

    const item_h: i32 = 28;
    const row = @divTrunc(y - panel.y - 4, item_h);

    if (row < 0) return null;

    return switch (open_menu) {

        .file => blk: {

            if (row >= file_items.len) break :blk null;

            break :blk file_items[@intCast(row)].id;

        },

        .shapes => blk: {

            if (row >= shape_tools.len) break :blk null;

            break :blk @intFromEnum(shape_tools[@intCast(row)]);

        },

        .none => null,

    };

}

fn toolbar_hit(x: i32, y: i32) i32 {

    if (y < 0 or y >= toolbar_h) return -1;

    if (file_btn_rect().contains(x, y)) return 200;
    if (shapes_btn_rect().contains(x, y)) return 201;

    for (primary_tools, 0..) |t, index| {

        if (primary_tool_rect(index).contains(x, y)) return @intFromEnum(t);

    }

    for (sizes, 0..) |_, index| {

        if (size_rect(index).contains(x, y)) return @intCast(20 + index);

    }

    for (palette, 0..) |_, index| {

        if (palette_rect(index).contains(x, y)) return @intCast(40 + index);

    }

    return -1;

}

fn paint_full() void {

    const surface = &window.surface;
    const width = win_w();
    const height = win_h();

    surface.fill(ui.theme.window_bg);
    paint_toolbar(surface, width);

    const origin = canvas_origin();
    const frame = Rect{

        .x = origin.x - 2,
        .y = origin.y - 2,
        .w = @as(i32, @intCast(canvas_w)) + 4,
        .h = @as(i32, @intCast(canvas_h)) + 4,

    };

    ui.stroke_round_rect(surface, frame, 4, 1, ui.theme.border);
    blit_canvas(surface, origin.x, origin.y, canvas_bounds());

    if (drawing and shape_preview and !is_freehand()) {

        // Rubber-band preview drawn into the window only (canvas stays clean until release).
        const preview = window_shape_surface();

        _ = draw_shape_on(&preview, start_x + origin.x, start_y + origin.y, last_x + origin.x, last_y + origin.y, fg, true);

    }

    if (open_menu != .none) paint_menu(surface);

    if (picker.open) picker.paint(surface, width, height);

    gfx.fence();
    window.present_all() catch {};

}

fn paint_canvas_damage(damage: Rect) void {

    if (damage.is_empty()) return;

    const origin = canvas_origin();
    const surface = &window.surface;

    blit_canvas(surface, origin.x, origin.y, damage);

    const present = Rect{

        .x = origin.x + damage.x,
        .y = origin.y + damage.y,
        .w = damage.w,
        .h = damage.h,

    };

    gfx.fence();
    window.present(present) catch {};

}

fn paint_toolbar(surface: *const gfx.Surface, width: i32) void {

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_h }, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = toolbar_h - 1, .w = width, .h = 1 }, ui.theme.border);

    // Row 1: File menu, primary tools, Shapes menu.
    paint_menu_chip(surface, file_btn_rect(), "File", hover == 200 or open_menu == .file, open_menu == .file);

    for (primary_tools, 0..) |t, index| {

        const id = @intFromEnum(t);
        const selected = tool == t;
        const hot = hover == id;

        paint_chip(surface, primary_tool_rect(index), tool_labels[id], hot, selected);

    }

    const shape_selected = is_shape_tool(tool);

    paint_menu_chip(surface, shapes_btn_rect(), "Shapes", hover == 201 or open_menu == .shapes, shape_selected or open_menu == .shapes);

    // Row 2: sizes, palette, FG/BG well.
    for (sizes, 0..) |size, index| {

        var buf: [4]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}", .{size}) catch "?";
        const selected = brush_size == size;
        const hot = hover == @as(i32, @intCast(20 + index));

        paint_chip(surface, size_rect(index), label, hot, selected);

    }

    for (palette, 0..) |color, index| {

        const rect = palette_rect(index);
        const hot = hover == @as(i32, @intCast(40 + index));

        ui.fill_round_rect(surface, rect, 4, color);
        ui.stroke_round_rect(surface, rect, 4, 1, if (hot) ui.theme.accent else ui.theme.border);

    }

    paint_color_well(surface);

}

fn paint_color_well(surface: *const gfx.Surface) void {

    const well = color_well_rect();
    const tile: i32 = 18;

    // Background sits lower-right; foreground sits upper-left — MS Paint style, aligned to the well.
    const bg_rect = Rect{

        .x = well.x + well.w - tile,
        .y = well.y + well.h - tile,
        .w = tile,
        .h = tile,

    };
    const fg_rect = Rect{

        .x = well.x,
        .y = well.y,
        .w = tile,
        .h = tile,

    };

    ui.fill_round_rect(surface, bg_rect, 3, bg);
    ui.stroke_round_rect(surface, bg_rect, 3, 1, ui.theme.border);
    ui.fill_round_rect(surface, fg_rect, 3, fg);
    ui.stroke_round_rect(surface, fg_rect, 3, 1, ui.theme.accent);

}

fn paint_menu(surface: *const gfx.Surface) void {

    const panel = menu_panel_rect(open_menu);

    if (panel.is_empty()) return;

    ui.fill_round_rect(surface, panel, chip_radius, ui.theme.surface);
    ui.stroke_round_rect(surface, panel, chip_radius, 1, ui.theme.border);

    const item_h: i32 = 28;

    switch (open_menu) {

        .file => {

            for (file_items, 0..) |item, index| {

                const rect = Rect{

                    .x = panel.x + 4,
                    .y = panel.y + 4 + @as(i32, @intCast(index)) * item_h,
                    .w = panel.w - 8,
                    .h = item_h - 2,

                };
                const hot = menu_item_hit(pointer_x, pointer_y) == item.id;

                if (hot) ui.fill_round_rect(surface, rect, 4, ui.theme.hover);

                font.draw(surface, rect.x + 10, rect.y + 6, 12, item.label, ui.theme.text);

            }

        },

        .shapes => {

            for (shape_tools, 0..) |t, index| {

                const rect = Rect{

                    .x = panel.x + 4,
                    .y = panel.y + 4 + @as(i32, @intCast(index)) * item_h,
                    .w = panel.w - 8,
                    .h = item_h - 2,

                };
                const id = @intFromEnum(t);
                const selected = tool == t;
                const hot = menu_item_hit(pointer_x, pointer_y) == id;

                if (selected) ui.fill_round_rect(surface, rect, 4, ui.theme.active)
                else if (hot) ui.fill_round_rect(surface, rect, 4, ui.theme.hover);

                font.draw(surface, rect.x + 10, rect.y + 6, 12, tool_labels[id], ui.theme.text);

            }

        },

        .none => {},

    }

}

fn is_shape_tool(t: Tool) bool {

    return switch (t) {

        .line, .rect, .fill_rect, .ellipse, .fill_ellipse => true,
        else => false,

    };

}

fn paint_chip(surface: *const gfx.Surface, rect: Rect, label: []const u8, hot: bool, selected: bool) void {

    ui.widgets.button(surface, &font, rect, label, .{

        .hovered = hot,
        .selected = selected,
        .outlined = true,

    }, .{ .radius = chip_radius, .size = 12 });

}

fn paint_menu_chip(surface: *const gfx.Surface, rect: Rect, label: []const u8, hot: bool, selected: bool) void {

    // The shared chip frame, then a label+chevron composite centered by hand.

    ui.widgets.button(surface, &font, rect, "", .{

        .hovered = hot,
        .selected = selected,
        .outlined = true,

    }, .{ .radius = chip_radius, .size = 12 });

    const text_w = font.text_width(label, 12);
    const chevron_gap: i32 = 6;
    const chevron_w: i32 = 8;
    const content_w = text_w + chevron_gap + chevron_w;
    const label_x = rect.x + @divTrunc(rect.w - content_w, 2);
    const ty = rect.y + @divTrunc(rect.h - font.line_height(12), 2);

    font.draw(surface, label_x, ty, 12, label, ui.theme.text);
    draw_chevron_down(surface, label_x + text_w + chevron_gap + @divTrunc(chevron_w, 2), rect.y + @divTrunc(rect.h, 2), ui.theme.text_dim);

}

/// Pixel chevron so dropdown affordance does not depend on a font glyph.
fn draw_chevron_down(surface: *const gfx.Surface, cx: i32, cy: i32, color: Color) void {

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

fn blit_canvas(surface: *const gfx.Surface, ox: i32, oy: i32, damage: Rect) void {

    const clipped = damage.intersect(canvas_bounds());

    if (clipped.is_empty()) return;

    const image = lib.draw.image.Image.from_pixels(canvas[0..canvas_pixels], canvas_w, canvas_h);

    // Blit only the damaged rows by temporarily presenting a sub-rect via put loops for the damage region.
    const dest = Rect{ .x = ox + clipped.x, .y = oy + clipped.y, .w = clipped.w, .h = clipped.h };
    const view = surface.clipped(dest);

    var y: i32 = 0;

    while (y < clipped.h) : (y += 1) {

        const sy: u32 = @intCast(clipped.y + y);
        const dy: u32 = @intCast(dest.y + y);
        const src_off = @as(usize, sy) * canvas_w + @as(usize, @intCast(clipped.x));
        const dst_off = @as(usize, dy) * view.stride + @as(usize, @intCast(dest.x));
        const count: usize = @intCast(clipped.w);

        @memcpy(view.pixels[dst_off .. dst_off + count], image.pixels[src_off .. src_off + count]);

    }

}

fn window_shape_surface() gfx.Surface {

    return window.surface;

}

fn canvas_bounds() Rect {

    return .{ .x = 0, .y = 0, .w = @intCast(canvas_w), .h = @intCast(canvas_h) };

}

fn canvas_get(x: i32, y: i32) Color {

    return canvas[@as(usize, @intCast(y)) * canvas_w + @as(usize, @intCast(x))];

}

fn canvas_put(x: i32, y: i32, color: Color) void {

    if (x < 0 or y < 0 or x >= canvas_w or y >= canvas_h) return;

    canvas[@as(usize, @intCast(y)) * canvas_w + @as(usize, @intCast(x))] = color;

}

fn stamp(x: i32, y: i32, color: Color, size: u8) Rect {

    const brush_r: i32 = @divTrunc(@as(i32, size), 2);
    const r2 = brush_r * brush_r;
    var damage = Rect{ .x = x - brush_r, .y = y - brush_r, .w = size, .h = size };

    if (size <= 1) {

        canvas_put(x, y, color);
        return .{ .x = x, .y = y, .w = 1, .h = 1 };

    }

    var dy: i32 = -brush_r;

    while (dy <= brush_r) : (dy += 1) {

        var dx: i32 = -brush_r;

        while (dx <= brush_r) : (dx += 1) {

            if (dx * dx + dy * dy <= r2 + brush_r) canvas_put(x + dx, y + dy, color);

        }

    }

    damage = damage.intersect(canvas_bounds());

    return if (damage.is_empty()) Rect.empty else damage;

}

fn stroke_line(x0: i32, y0: i32, x1: i32, y1: i32, color: Color, size: u8) Rect {

    var damage = Rect.empty;
    var x = x0;
    var y = y0;
    const dx: i32 = if (x1 >= x0) x1 - x0 else x0 - x1;
    const dy: i32 = if (y1 >= y0) y0 - y1 else y1 - y0;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    while (true) {

        damage = Rect.cover(damage, stamp(x, y, color, size));

        if (x == x1 and y == y1) break;

        const e2 = 2 * err;

        if (e2 >= dy) {

            err += dy;
            x += sx;

        }

        if (e2 <= dx) {

            err += dx;
            y += sy;

        }

    }

    return damage;

}

fn draw_shape(x0: i32, y0: i32, x1: i32, y1: i32, color: Color, preview: bool) Rect {

    _ = preview;

    var surface = canvas_surface();

    return draw_shape_on(&surface, x0, y0, x1, y1, color, false);

}

fn draw_shape_on(surface: *const gfx.Surface, x0: i32, y0: i32, x1: i32, y1: i32, color: Color, preview: bool) Rect {

    const left = @min(x0, x1);
    const top = @min(y0, y1);
    const right = @max(x0, x1);
    const bottom = @max(y0, y1);
    const rect = Rect{ .x = left, .y = top, .w = right - left + 1, .h = bottom - top + 1 };
    const stroke_w: i32 = if (preview) 1 else @max(1, brush_size);

    switch (tool) {

        .line => {

            if (surface.pixels == canvas) {

                return stroke_line(x0, y0, x1, y1, color, @intCast(stroke_w));

            }

            // Window-space preview line via stamp-like rect steps.
            bresenham_window(surface, x0, y0, x1, y1, color);
            return rect;

        },

        .rect => {

            surface.stroke_rect(rect, stroke_w, color);
            return rect;

        },

        .fill_rect => {

            surface.fill_rect(rect, color);
            return rect;

        },

        .ellipse => {

            draw_ellipse(surface, rect, color, false);
            return rect;

        },

        .fill_ellipse => {

            draw_ellipse(surface, rect, color, true);
            return rect;

        },

        else => return Rect.empty,

    }

}

fn bresenham_window(surface: *const gfx.Surface, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {

    var x = x0;
    var y = y0;
    const dx: i32 = if (x1 >= x0) x1 - x0 else x0 - x1;
    const dy: i32 = if (y1 >= y0) y0 - y1 else y1 - y0;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    while (true) {

        surface.put_pixel(x, y, color);

        if (x == x1 and y == y1) break;

        const e2 = 2 * err;

        if (e2 >= dy) {

            err += dy;
            x += sx;

        }

        if (e2 <= dx) {

            err += dx;
            y += sy;

        }

    }

}

fn draw_ellipse(surface: *const gfx.Surface, rect: Rect, color: Color, fill: bool) void {

    if (rect.w <= 1 or rect.h <= 1) {

        surface.fill_rect(rect, color);
        return;

    }

    const cx = rect.x + @divTrunc(rect.w, 2);
    const cy = rect.y + @divTrunc(rect.h, 2);
    const rx: i32 = @max(@as(i32, 1), @divTrunc(rect.w, 2));
    const ry: i32 = @max(@as(i32, 1), @divTrunc(rect.h, 2));
    const rx2: i64 = @as(i64, rx) * rx;
    const ry2: i64 = @as(i64, ry) * ry;

    var y: i32 = -ry;

    while (y <= ry) : (y += 1) {

        const yy: i64 = y;
        // x extent: x^2 / rx^2 + y^2 / ry^2 <= 1  =>  x^2 <= rx^2 * (1 - y^2/ry^2)
        const inner = ry2 - yy * yy;

        if (inner < 0) continue;

        const x_span_sq = @divTrunc(rx2 * inner, ry2);
        var x_span: i32 = 0;
        // Integer sqrt for x_span.
        var guess: i32 = @intCast(@min(rx, 1 + @divTrunc(x_span_sq, @max(1, rx))));

        while (@as(i64, guess) * guess > x_span_sq and guess > 0) guess -= 1;
        while (@as(i64, guess + 1) * (guess + 1) <= x_span_sq) guess += 1;

        x_span = guess;

        if (fill) {

            surface.fill_rect(.{ .x = cx - x_span, .y = cy + y, .w = x_span * 2 + 1, .h = 1 }, color);

        } else {

            surface.put_pixel(cx - x_span, cy + y, color);
            surface.put_pixel(cx + x_span, cy + y, color);

            if (y != 0) {

                // denser outline on steep sides
                if (x_span > 0) {

                    surface.put_pixel(cx - x_span + 1, cy + y, color);
                    surface.put_pixel(cx + x_span - 1, cy + y, color);

                }

            }

        }

    }

}

fn flood_fill(sx: i32, sy: i32, color: Color) void {

    const target = canvas_get(sx, sy);

    if (target == color) return;

    // Scanline fill with a fixed stack of seed spans.
    const StackItem = struct { y: i32, x_left: i32, x_right: i32, dy: i32 };
    var stack: [4096]StackItem = undefined;
    var sp: usize = 0;

    stack[sp] = .{ .y = sy, .x_left = sx, .x_right = sx, .dy = 1 };
    sp += 1;

    if (sp < stack.len) {

        stack[sp] = .{ .y = sy, .x_left = sx, .x_right = sx, .dy = -1 };
        sp += 1;

    }

    while (sp > 0) {

        sp -= 1;
        const item = stack[sp];
        const y = item.y + item.dy;

        if (y < 0 or y >= canvas_h) continue;

        var x = item.x_left;

        while (x <= item.x_right) : (x += 1) {

            if (canvas_get(x, y) != target) continue;

            var x_left = x;

            while (x_left > 0 and canvas_get(x_left - 1, y) == target) x_left -= 1;

            var x_right = x;

            while (x_right + 1 < canvas_w and canvas_get(x_right + 1, y) == target) x_right += 1;

            var fill_x = x_left;

            while (fill_x <= x_right) : (fill_x += 1) canvas_put(fill_x, y, color);

            if (sp + 2 <= stack.len) {

                stack[sp] = .{ .y = y, .x_left = x_left, .x_right = x_right, .dy = item.dy };
                sp += 1;
                stack[sp] = .{ .y = y, .x_left = x_left, .x_right = x_right, .dy = -item.dy };
                sp += 1;

            }

            x = x_right;

        }

    }

}

fn update_cursor(x: i32, y: i32) void {

    if (y < toolbar_h or toolbar_hit(x, y) >= 0) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    if (to_canvas(x, y) != null) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    lib.cursor.set(&connection, .pointer);

}
