// Compositor chrome rendering (M10 GUI rewrite): decorated windows get a frame - a title bar with Inter text
// and a close cross, client content blitted with the bottom corners cut by quarter-circle coverage masks - all
// through fast masked fills and blits. Because windows composite bottom-up into the back buffer, the masked
// corners naturally reveal whatever lies beneath, so rounding costs two small masked blits per window and
// nothing else.

const std = @import("std");

const lib = @import("lib");

const draw = lib.draw;

const manager_module = @import("manager.zig");

const Color = draw.Color;
const Face = draw.text.Face;
const Rect = draw.Rect;
const Surface = draw.Surface;
const Window = manager_module.Window;

pub const corner_radius: i32 = 8;
pub const title_font_size: u32 = 13;

pub const Chrome = struct {

    title_focused: Color,
    title_blurred: Color,
    text: Color,

};

fn content_corner_masks() ?draw.round.Masks {

    return draw.round.masks_for(corner_radius);

}

pub fn draw_title_bar(back: *const Surface, window: *const Window, focused: bool, chrome: Chrome, font: ?*const Face) void {

    const bar = window.title_bar();
    const color = if (focused) chrome.title_focused else chrome.title_blurred;

    draw.round.fill_round_top_rect(back, bar, corner_radius, color);

    if (font) |face| {

        draw_title_text(back, window, bar, chrome, face);

    }

    draw_minimize_button(back, window.minimize_button(), chrome);
    draw_maximize_button(back, window.maximize_button(), chrome, window.is_maximized());
    draw_close_button(back, window.close_button(), chrome);

}

fn draw_title_text(back: *const Surface, window: *const Window, bar: Rect, chrome: Chrome, face: *const Face) void {

    const title = window.title[0..window.title_length];
    const max_w = bar.w - Window.chrome_reserved_width() - manager_module.title_padding;

    if (max_w <= 0 or title.len == 0) return;

    var length = title.len;

    while (length > 0 and face.text_width(title[0..length], title_font_size) > max_w) : (length -= 1) {}

    const clipped = back.clipped(bar);
    const text_y = bar.y + @divTrunc(bar.h - face.line_height(title_font_size), 2);

    face.draw(&clipped, bar.x + manager_module.title_padding, text_y, title_font_size, title[0..length], chrome.text);

}

fn draw_minimize_button(back: *const Surface, box: Rect, chrome: Chrome) void {

    const cx = box.x + @divTrunc(box.w, 2);
    const cy = box.y + @divTrunc(box.h, 2);
    const arm = @max(2, @divTrunc(box.w, 4));

    stroke_line(back, cx - arm, cy + arm, cx + arm, cy + arm, chrome.text);

}

fn draw_maximize_button(back: *const Surface, box: Rect, chrome: Chrome, maximized: bool) void {

    const inset = @max(2, @divTrunc(box.w, 5));
    const outer = Rect{

        .x = box.x + inset,
        .y = box.y + inset,
        .w = box.w - 2 * inset,
        .h = box.h - 2 * inset,

    };

    if (maximized) {

        // Restored glyph: overlapping squares.
        const shift = @max(1, @divTrunc(inset, 2));
        const back_box = Rect{ .x = outer.x + shift, .y = outer.y, .w = outer.w - shift, .h = outer.h - shift };
        const front = Rect{ .x = outer.x, .y = outer.y + shift, .w = outer.w - shift, .h = outer.h - shift };

        stroke_rect(back, back_box, chrome.text);
        stroke_rect(back, front, chrome.text);

    } else {

        stroke_rect(back, outer, chrome.text);

    }

}

fn draw_close_button(back: *const Surface, box: Rect, chrome: Chrome) void {

    const cx = box.x + @divTrunc(box.w, 2);
    const cy = box.y + @divTrunc(box.h, 2);
    const arm = @max(2, @divTrunc(box.w, 4));

    stroke_line(back, cx - arm, cy - arm, cx + arm, cy + arm, chrome.text);
    stroke_line(back, cx + arm, cy - arm, cx - arm, cy + arm, chrome.text);

}

fn stroke_rect(back: *const Surface, box: Rect, color: Color) void {

    if (box.w <= 0 or box.h <= 0) return;

    stroke_line(back, box.x, box.y, box.x + box.w - 1, box.y, color);
    stroke_line(back, box.x, box.y + box.h - 1, box.x + box.w - 1, box.y + box.h - 1, color);
    stroke_line(back, box.x, box.y, box.x, box.y + box.h - 1, color);
    stroke_line(back, box.x + box.w - 1, box.y, box.x + box.w - 1, box.y + box.h - 1, color);

}

fn stroke_line(back: *const Surface, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {

    var x = x0;
    var y = y0;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = @intCast(@abs(y1 - y0));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;

    var err = dx - dy;

    while (true) {

        back.put_pixel(x, y, color);

        if (x == x1 and y == y1) break;

        const e2 = 2 * err;

        if (e2 > -dy) {

            err -= dy;
            x += sx;

        }

        if (e2 < dx) {

            err += dx;
            y += sy;

        }

    }

}

/// Blit the client's content into the back buffer, cutting decorated windows' bottom corners with the
/// quarter-circle masks so what was already composited beneath shows through.
pub fn blit_content(back: *const Surface, window: *const Window, surface: *const Surface, clip: Rect, matte: Color) void {

    const content = window.content();
    const visible = content.intersect(clip);

    if (visible.is_empty()) return;

    if (!window.decorated() or content.h <= corner_radius or content.w <= 2 * corner_radius) {

        back.blit(visible.x, visible.y, surface, visible.translated(-content.x, -content.y));

        return;

    }

    const masks = content_corner_masks() orelse {

        back.blit(visible.x, visible.y, surface, visible.translated(-content.x, -content.y));

        return;

    };

    const r = corner_radius;
    const body = Rect{ .x = content.x, .y = content.y, .w = content.w, .h = content.h - r };
    const strip = Rect{ .x = content.x + r, .y = content.y + content.h - r, .w = content.w - 2 * r, .h = r };

    const body_visible = body.intersect(clip);

    if (!body_visible.is_empty()) {

        back.blit(body_visible.x, body_visible.y, surface, body_visible.translated(-content.x, -content.y));

    }

    const strip_visible = strip.intersect(clip);

    if (!strip_visible.is_empty()) {

        back.blit(strip_visible.x, strip_visible.y, surface, strip_visible.translated(-content.x, -content.y));

    }

    const corner_y = content.y + content.h - r;
    const left = Rect{ .x = content.x, .y = corner_y, .w = r, .h = r };
    const right = Rect{ .x = content.x + content.w - r, .y = corner_y, .w = r, .h = r };

    const side: u32 = @intCast(r);

    if (!left.intersect(clip).is_empty()) {

        const view = back.clipped(clip);

        draw.round.matte_corner_edges(&view, left.x, left.y, masks.bl, side, matte);
        view.blit_masked(left.x, left.y, surface, left.translated(-content.x, -content.y), masks.bl, side);

    }

    if (!right.intersect(clip).is_empty()) {

        const view = back.clipped(clip);

        draw.round.matte_corner_edges(&view, right.x, right.y, masks.br, side, matte);
        view.blit_masked(right.x, right.y, surface, right.translated(-content.x, -content.y), masks.br, side);

    }

}

/// A trio of short ticks in the bottom-right corner: the resize affordance.
pub fn draw_resize_grip(back: *const Surface, window: *const Window, color: Color) void {

    const grip = window.resize_grip_rect();
    const corner_x = grip.x + grip.w - 4;
    const corner_y = grip.y + grip.h - 4;

    var step: i32 = 4;

    while (step <= 12) : (step += 4) {

        stroke_line(back, corner_x - step, corner_y, corner_x, corner_y - step, color);

    }

}

/// One-pixel frame outline: rect fills + cached corner rims (no path raster on the drag hot path).
pub fn draw_frame_border(back: *const Surface, window: *const Window, color: Color) void {

    draw.round.stroke_round_rect_fast(back, window.frame(), corner_radius, 1, color);

}

/// The interactive-resize rubber band (fast path is fine: temporary, not chrome).
pub fn draw_outline(back: *const Surface, rect: Rect, color: Color) void {

    draw.round.stroke_round_rect_fast(back, rect, corner_radius, 2, color);

}

const testing = std.testing;

test "content corner masks are opaque inside and clear outside the arc" {

    const masks = content_corner_masks() orelse return error.TestExpectedEqual;
    const r: usize = @intCast(corner_radius);

    try testing.expectEqual(@as(u8, 255), masks.bl[r - 1]);
    try testing.expect(masks.bl[(r - 1) * r] < 64);
    try testing.expectEqual(@as(u8, 255), masks.br[0]);
    try testing.expect(masks.br[r * r - 1] < 64);

}