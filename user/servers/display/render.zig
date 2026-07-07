// Compositor chrome rendering (M10 GUI rewrite): decorated windows get an antialiased frame - a rounded-top
// title bar with Inter text and a stroked close cross, client content blitted with the bottom corners cut by
// quarter-circle coverage masks - all through the analytic renderer. Because windows composite bottom-up into
// the back buffer, the masked corners naturally reveal whatever lies beneath, so rounding costs two small
// masked blits per window and nothing else.

const std = @import("std");

const lib = @import("lib");

const draw = lib.draw;

const manager_module = @import("manager.zig");

const Color = draw.Color;
const Face = draw.text.Face;
const Path = draw.path.Path;
const Rect = draw.Rect;
const Surface = draw.Surface;
const Window = manager_module.Window;

const fx = draw.path.from_px;

pub const corner_radius: i32 = 8;
pub const title_font_size: u32 = 13;

pub const Chrome = struct {

    title_focused: Color,
    title_blurred: Color,
    text: Color,

};

// Quarter-circle corner masks for the content's bottom corners, rebuilt only when the radius constant moves.

var masks_ready = false;
var mask_left: [corner_radius * corner_radius]u8 = undefined;
var mask_right: [corner_radius * corner_radius]u8 = undefined;

fn build_masks() void {

    const r = corner_radius;
    const side: u32 = @intCast(2 * r);

    var coverage: [4 * corner_radius * corner_radius]u8 = [_]u8{0} ** (4 * corner_radius * corner_radius);

    var path = Path{};

    path.add_round_rect(0, 0, fx(2 * r), fx(2 * r), fx(r));
    draw.raster.fill_coverage(&path, &coverage, side, side, 0, 0);

    // The bottom-left and bottom-right quadrants of the disc-cornered square.

    var row: usize = 0;

    while (row < r) : (row += 1) {

        const src = (row + @as(usize, @intCast(r))) * side;

        for (0..@intCast(r)) |col| {

            mask_left[row * @as(usize, @intCast(r)) + col] = coverage[src + col];
            mask_right[row * @as(usize, @intCast(r)) + col] = coverage[src + @as(usize, @intCast(r)) + col];

        }

    }

    masks_ready = true;

}

/// A rectangle with only its top corners rounded (the title bar shape).
fn add_round_top_rect(path: *Path, x: i32, y: i32, w: i32, h: i32, radius: i32) void {

    const r = @max(0, @min(radius, @min(@divTrunc(w, 2), h)));

    if (r == 0) return path.add_rect(x, y, w, h);

    const k = @divTrunc(@as(i32, @intCast(@as(i64, r) * 36195)), 65536);

    path.move_to(x + r, y);
    path.line_to(x + w - r, y);
    path.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    path.line_to(x + w, y + h);
    path.line_to(x, y + h);
    path.line_to(x, y + r);
    path.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    path.close();

}

pub fn draw_title_bar(back: *const Surface, window: *const Window, focused: bool, chrome: Chrome, font: ?*const Face) void {

    const bar = window.title_bar();
    const color = if (focused) chrome.title_focused else chrome.title_blurred;

    var path = Path{};

    add_round_top_rect(&path, fx(bar.x), fx(bar.y), fx(bar.w), fx(bar.h), fx(corner_radius));
    draw.raster.fill(back, &path, color);

    if (font) |face| {

        draw_title_text(back, window, bar, chrome, face);

    }

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

fn draw_close_button(back: *const Surface, box: Rect, chrome: Chrome) void {

    const cx = box.x + @divTrunc(box.w, 2);
    const cy = box.y + @divTrunc(box.h, 2);
    const arm = @max(2, @divTrunc(box.w, 4));

    var path = Path{};

    draw.stroke.segment(&path, fx(cx - arm), fx(cy - arm), fx(cx + arm), fx(cy + arm), fx(1) + 32);
    draw.stroke.segment(&path, fx(cx + arm), fx(cy - arm), fx(cx - arm), fx(cy + arm), fx(1) + 32);
    draw.raster.fill(back, &path, chrome.text);

}

/// Blit the client's content into the back buffer, cutting decorated windows' bottom corners with the
/// quarter-circle masks so what was already composited beneath shows through.
pub fn blit_content(back: *const Surface, window: *const Window, surface: *const Surface, clip: Rect) void {

    const content = window.content();
    const visible = content.intersect(clip);

    if (visible.is_empty()) return;

    if (!window.decorated() or content.h <= corner_radius or content.w <= 2 * corner_radius) {

        back.blit(visible.x, visible.y, surface, visible.translated(-content.x, -content.y));

        return;

    }

    if (!masks_ready) build_masks();

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

    if (!left.intersect(clip).is_empty()) {

        const view = back.clipped(clip);

        view.blit_masked(left.x, left.y, surface, left.translated(-content.x, -content.y), &mask_left, @intCast(r));

    }

    if (!right.intersect(clip).is_empty()) {

        const view = back.clipped(clip);

        view.blit_masked(right.x, right.y, surface, right.translated(-content.x, -content.y), &mask_right, @intCast(r));

    }

}

/// A trio of short antialiased ticks in the bottom-right corner: the resize affordance.
pub fn draw_resize_grip(back: *const Surface, window: *const Window, color: Color) void {

    const grip = window.resize_grip_rect();
    const corner_x = grip.x + grip.w - 4;
    const corner_y = grip.y + grip.h - 4;

    var path = Path{};

    var step: i32 = 4;

    while (step <= 12) : (step += 4) {

        draw.stroke.segment(&path, fx(corner_x - step), fx(corner_y), fx(corner_x), fx(corner_y - step), 80);

    }

    draw.raster.fill(back, &path, color);

}

/// The interactive-resize rubber band: a two-pixel antialiased rounded outline.
pub fn draw_outline(back: *const Surface, rect: Rect, color: Color) void {

    var path = Path{};

    draw.stroke.round_rect_border(&path, fx(rect.x), fx(rect.y), fx(rect.w), fx(rect.h), fx(corner_radius), fx(2));
    draw.raster.fill(back, &path, color);

}

const testing = std.testing;

test "corner masks are opaque at the inner corner and clear at the outer tip" {

    build_masks();

    const r: usize = @intCast(corner_radius);

    // Bottom-left mask: top-right cell is deep inside the shape; bottom-left cell is outside the arc.

    try testing.expectEqual(@as(u8, 255), mask_left[r - 1]);
    try testing.expect(mask_left[(r - 1) * r] < 64);

    // Bottom-right mask mirrors it.

    try testing.expectEqual(@as(u8, 255), mask_right[0]);
    try testing.expect(mask_right[r * r - 1] < 64);

}

test "round-top rect path stays within bounds" {

    var path = Path{};

    add_round_top_rect(&path, 0, 0, fx(100), fx(28), fx(8));

    try testing.expect(!path.overflowed);
    try testing.expect(path.verb_count > 4);

}
