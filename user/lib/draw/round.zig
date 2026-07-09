// Fast rounded rectangles: the body is plain rect fills; only the four r×r corner cells go through
// precomputed quarter-circle coverage masks (same analytic source as the full rasterizer). Large radii or
// uncached values fall back to one full-path fill so every caller shares one correct implementation.

const std = @import("std");

const draw_mod = @import("draw.zig");
const path_mod = @import("path.zig");
const raster = @import("raster.zig");
const stroke = @import("stroke.zig");

const Color = draw_mod.Color;
const Path = path_mod.Path;
const Rect = draw_mod.Rect;
const Surface = draw_mod.Surface;

pub const max_radius: i32 = 32;

pub const Masks = struct {

    r: i32,
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,

    // 1px perimeter of each quarter — precomputed so frame borders avoid per-pixel edge walks.
    rim_tl: []const u8,
    rim_tr: []const u8,
    rim_bl: []const u8,
    rim_br: []const u8,

};

const Slot = struct {

    ready: bool = false,

    tl: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),
    tr: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),
    bl: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),
    br: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),

    rim_tl: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),
    rim_tr: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),
    rim_bl: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),
    rim_br: [max_radius * max_radius]u8 = [_]u8{0} ** (max_radius * max_radius),

    fn view(self: *const Slot, r: i32) Masks {

        const area: usize = @intCast(r * r);

        return .{

            .r = r,
            .tl = self.tl[0..area],
            .tr = self.tr[0..area],
            .bl = self.bl[0..area],
            .br = self.br[0..area],

            .rim_tl = self.rim_tl[0..area],
            .rim_tr = self.rim_tr[0..area],
            .rim_bl = self.rim_bl[0..area],
            .rim_br = self.rim_br[0..area],

        };

    }

};

// One slot per radius so returned mask slices never alias a reused cache entry.
var cache: [max_radius + 1]Slot = [_]Slot{.{}} ** (max_radius + 1);

pub fn clamp_radius(rect: Rect, radius: i32) i32 {

    return @max(0, @min(radius, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2))));

}

/// Cached quarter-circle masks for `radius` pixels (clamped to `max_radius`).
pub fn masks_for(radius: i32) ?Masks {

    if (radius <= 0 or radius > max_radius) return null;

    const r = radius;
    const slot = &cache[@intCast(r)];

    if (!slot.ready) build_masks(slot, r);

    return slot.view(r);

}

pub fn fill_round_rect(surface: *const Surface, rect: Rect, radius: i32, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0) return;

    const r = clamp_radius(rect, radius);

    if (r <= 1) {

        surface.fill_rect(rect, color);

        return;

    }

    if (masks_for(r)) |masks| {

        fill_round_rect_masked(surface, rect, r, masks, color);

        return;

    }

    fill_round_rect_slow(surface, rect, radius, color);

}

/// Fill a rectangle with only its top two corners rounded (title bars, tabs docked to an edge).
pub fn fill_round_top_rect(surface: *const Surface, rect: Rect, radius: i32, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0) return;

    const r = clamp_radius(rect, radius);

    if (r <= 1) {

        surface.fill_rect(rect, color);

        return;

    }

    if (masks_for(r)) |masks| {

        fill_round_top_rect_masked(surface, rect, r, masks, color);

        return;

    }

    fill_round_top_rect_slow(surface, rect, radius, color);

}

pub fn stroke_round_rect(surface: *const Surface, rect: Rect, radius: i32, width: i32, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0 or width <= 0) return;

    // Analytic outer/inner ring: corner arcs stay continuous with the filled chrome and meet the
    // straight edges without the 1px perimeter approximation of stroke_round_rect_fast.
    var shape = Path{};

    stroke.round_rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius), path_mod.from_px(width));
    raster.fill(surface, &shape, color);

}

/// Straight edges as rect fills; corner arcs from precomputed 1px rim masks. Hot path for the
/// compositor — no path flatten/sweep per frame.
pub fn stroke_round_rect_fast(surface: *const Surface, rect: Rect, radius: i32, width: i32, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0 or width <= 0) return;

    const r = clamp_radius(rect, radius);
    const band = width;

    if (r <= band) {

        surface.stroke_rect(rect, band, color);

        return;

    }

    surface.fill_rect(.{ .x = rect.x + r, .y = rect.y, .w = rect.w - 2 * r, .h = band }, color);
    surface.fill_rect(.{ .x = rect.x + r, .y = rect.y + rect.h - band, .w = rect.w - 2 * r, .h = band }, color);
    surface.fill_rect(.{ .x = rect.x, .y = rect.y + r, .w = band, .h = rect.h - 2 * r }, color);
    surface.fill_rect(.{ .x = rect.x + rect.w - band, .y = rect.y + r, .w = band, .h = rect.h - 2 * r }, color);

    if (masks_for(r)) |masks| {

        const side: u32 = @intCast(r);

        // band > 1: expand by blending the solid fill mask under a second inset pass is rare (resize
        // rubber band). A second blend of the full fill at the rim is enough for a short 2px stroke.
        surface.blend_coverage(rect.x, rect.y, masks.rim_tl, side, side, color);
        surface.blend_coverage(rect.x + rect.w - r, rect.y, masks.rim_tr, side, side, color);
        surface.blend_coverage(rect.x, rect.y + rect.h - r, masks.rim_bl, side, side, color);
        surface.blend_coverage(rect.x + rect.w - r, rect.y + rect.h - r, masks.rim_br, side, side, color);

        if (band > 1) {

            // One more inward ring: solid edge pixels of the fill (rim already has the outer fringe).
            stroke_inward_band(surface, rect.x, rect.y, masks.tl, side, color);
            stroke_inward_band(surface, rect.x + rect.w - r, rect.y, masks.tr, side, color);
            stroke_inward_band(surface, rect.x, rect.y + rect.h - r, masks.bl, side, color);
            stroke_inward_band(surface, rect.x + rect.w - r, rect.y + rect.h - r, masks.br, side, color);

        }

    }

}

fn stroke_inward_band(surface: *const Surface, x: i32, y: i32, fill: []const u8, side: u32, color: Color) void {

    var row: u32 = 0;

    while (row < side) : (row += 1) {

        var col: u32 = 0;

        while (col < side) : (col += 1) {

            if (fill[row * side + col] != 255) continue;
            if (!has_zero_neighbor(fill, side, row, col)) continue;

            surface.put_pixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color);

        }

    }

}

fn has_zero_neighbor(fill: []const u8, side: u32, row: u32, col: u32) bool {

    if (row > 0 and fill[(row - 1) * side + col] == 0) return true;
    if (col > 0 and fill[row * side + col - 1] == 0) return true;
    if (row + 1 < side and fill[(row + 1) * side + col] == 0) return true;
    if (col + 1 < side and fill[row * side + col + 1] == 0) return true;

    return false;

}

fn fill_edge(fill: []const u8, side: u32, row: u32, col: u32) bool {

    if (fill[row * side + col] == 0) return false;

    return has_zero_neighbor(fill, side, row, col);

}

/// Prime anti-aliased edge pixels so a masked blit blends against `matte`, not whatever was beneath.
pub fn matte_corner_edges(surface: *const Surface, x: i32, y: i32, fill_mask: []const u8, side: u32, matte: Color) void {

    var row: u32 = 0;

    while (row < side) : (row += 1) {

        const start = row * side;

        var col: u32 = 0;

        while (col < side) : (col += 1) {

            const alpha = fill_mask[start + col];

            if (alpha > 0 and alpha < 255) {

                surface.put_pixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), matte);

            }

        }

    }

}

fn fill_round_rect_masked(surface: *const Surface, rect: Rect, r: i32, masks: Masks, color: Color) void {

    surface.fill_rect(.{ .x = rect.x + r, .y = rect.y, .w = rect.w - 2 * r, .h = rect.h }, color);
    surface.fill_rect(.{ .x = rect.x, .y = rect.y + r, .w = rect.w, .h = rect.h - 2 * r }, color);

    const side: u32 = @intCast(r);

    surface.blend_coverage(rect.x, rect.y, masks.tl, side, side, color);
    surface.blend_coverage(rect.x + rect.w - r, rect.y, masks.tr, side, side, color);
    surface.blend_coverage(rect.x, rect.y + rect.h - r, masks.bl, side, side, color);
    surface.blend_coverage(rect.x + rect.w - r, rect.y + rect.h - r, masks.br, side, side, color);

}

fn fill_round_top_rect_masked(surface: *const Surface, rect: Rect, r: i32, masks: Masks, color: Color) void {

    surface.fill_rect(.{ .x = rect.x, .y = rect.y + r, .w = rect.w, .h = rect.h - r }, color);
    surface.fill_rect(.{ .x = rect.x + r, .y = rect.y, .w = rect.w - 2 * r, .h = r }, color);

    const side: u32 = @intCast(r);

    surface.blend_coverage(rect.x, rect.y, masks.tl, side, side, color);
    surface.blend_coverage(rect.x + rect.w - r, rect.y, masks.tr, side, side, color);

}

fn fill_round_rect_slow(surface: *const Surface, rect: Rect, radius: i32, color: Color) void {

    var shape = Path{};

    shape.add_round_rect(path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius));
    raster.fill(surface, &shape, color);

}

fn fill_round_top_rect_slow(surface: *const Surface, rect: Rect, radius: i32, color: Color) void {

    var shape = Path{};

    add_round_top_rect(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius));
    raster.fill(surface, &shape, color);

}

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

fn build_masks(slot: *Slot, r: i32) void {

    slot.ready = false;

    const side: u32 = @intCast(2 * r);
    const cells = side * side;
    const corner: u32 = @intCast(r);
    const corner_cells = corner * corner;

    var coverage: [4 * max_radius * max_radius]u8 = [_]u8{0} ** (4 * max_radius * max_radius);

    var path = Path{};

    path.add_round_rect(0, 0, path_mod.from_px(2 * r), path_mod.from_px(2 * r), path_mod.from_px(r));
    raster.fill_coverage(&path, coverage[0..cells], side, side, 0, 0);

    extract_quadrants(coverage[0..cells], side, r, slot.tl[0..], slot.tr[0..], slot.bl[0..], slot.br[0..]);

    extract_rim(slot.tl[0..corner_cells], corner, slot.rim_tl[0..corner_cells]);
    extract_rim(slot.tr[0..corner_cells], corner, slot.rim_tr[0..corner_cells]);
    extract_rim(slot.bl[0..corner_cells], corner, slot.rim_bl[0..corner_cells]);
    extract_rim(slot.br[0..corner_cells], corner, slot.rim_br[0..corner_cells]);

    slot.ready = true;

}

fn extract_rim(fill: []const u8, side: u32, rim: []u8) void {

    const area = side * side;

    @memset(rim[0..area], 0);

    var row: u32 = 0;

    while (row < side) : (row += 1) {

        var col: u32 = 0;

        while (col < side) : (col += 1) {

            if (!fill_edge(fill, side, row, col)) continue;

            rim[row * side + col] = fill[row * side + col];

        }

    }

}

fn extract_quadrants(coverage: []const u8, side: u32, r: i32, tl: []u8, tr: []u8, bl: []u8, br: []u8) void {

    const edge: usize = @intCast(r);

    var row: usize = 0;

    while (row < edge) : (row += 1) {

        const top = row * side;
        const bottom = (row + edge) * side;

        var col: usize = 0;

        while (col < edge) : (col += 1) {

            const local = row * edge + col;

            tl[local] = coverage[top + col];
            tr[local] = coverage[top + edge + col];
            bl[local] = coverage[bottom + col];
            br[local] = coverage[bottom + edge + col];

        }

    }

}

const testing = std.testing;

test "fast fill matches the slow path on a rounded panel" {

    var fast_buf: [64 * 64]u32 = [_]u32{0xff0000} ** (64 * 64);
    var slow_buf: [64 * 64]u32 = [_]u32{0xff0000} ** (64 * 64);

    const fast_surface = Surface.from_pixels(&fast_buf, 64, 64);
    const slow_surface = Surface.from_pixels(&slow_buf, 64, 64);

    const rect = Rect{ .x = 8, .y = 8, .w = 40, .h = 24 };

    fill_round_rect(&fast_surface, rect, 6, 0x336699);
    fill_round_rect_slow(&slow_surface, rect, 6, 0x336699);

    try testing.expectEqualSlices(u32, &slow_buf, &fast_buf);

}

test "fast round-top fill matches the slow path" {

    var fast_buf: [64 * 64]u32 = [_]u32{0xff0000} ** (64 * 64);
    var slow_buf: [64 * 64]u32 = [_]u32{0xff0000} ** (64 * 64);

    const fast_surface = Surface.from_pixels(&fast_buf, 64, 64);
    const slow_surface = Surface.from_pixels(&slow_buf, 64, 64);

    const rect = Rect{ .x = 4, .y = 4, .w = 48, .h = 28 };

    fill_round_top_rect(&fast_surface, rect, 8, 0x445566);
    fill_round_top_rect_slow(&slow_surface, rect, 8, 0x445566);

    try testing.expectEqualSlices(u32, &slow_buf, &fast_buf);

}

test "corner masks are opaque inside and clear outside the arc" {

    const masks = masks_for(8) orelse return error.TestExpectedEqual;
    const r: usize = 8;

    // Interior of each quarter (toward the rect center) is solid; the outer open corner is clear.
    // Allow a small undershoot from cubic circle arcs (linear coverage, no display gamma).
    try testing.expect(masks.tl[(r - 1) * r + (r - 1)] >= 240);
    try testing.expect(masks.tl[0] < 64);
    try testing.expect(masks.br[0] >= 240);
    try testing.expect(masks.br[r * r - 1] < 64);

}