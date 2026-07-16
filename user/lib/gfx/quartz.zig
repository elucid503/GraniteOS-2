const std = @import("std");

const draw = @import("../draw/draw.zig");

const Color = draw.Color;
const Rect = draw.Rect;
const Surface = draw.Surface;

// Displacement is signed i8 in 1/16-pixel units.
const fixed_one: i32 = 16;
const max_fixed: i32 = 127;
const curve_table = make_curve_table();

// Wide convex bezel → background edges visibly wrap around the glass rim.
const bezel_width: i32 = 20;
const control_bezel: i32 = 14;
const control_refraction: i32 = 7 * fixed_one;
const element_opacity: u8 = 72;
const panel_border = draw.rgba(255, 255, 255, 30);
const control_border = draw.rgba(255, 255, 255, 26);

pub const Kind = enum {

    regular,
    clear,
    prominent,

};

pub const Style = struct {

    radius: i32,
    bezel: i32,
    refraction: i32,

    fill: Color,
    shadow: Color,

    control: Color,
    control_alpha: u8,
    control_hover: Color,
    control_hover_alpha: u8,

};

pub fn material_opacity(kind: Kind) u8 {

    return switch (kind) {

        .regular => 156,
        .clear => 100,
        .prominent => 212,

    };

}

pub fn style(kind: Kind, tint: Color, accent: Color) Style {

    return .{

        .radius = 24,
        .bezel = bezel_width,
        // Density controls darkness only; every Quartz container bends the backdrop identically.
        .refraction = max_fixed,

        .fill = draw.with_alpha(tint, material_opacity(kind)),
        .shadow = draw.rgba(0, 0, 0, 48),

        .control = draw.rgb(255, 255, 255),
        .control_alpha = 28,
        .control_hover = accent,
        .control_hover_alpha = 80,

    };

}

pub fn unfocused(appearance: Style) Style {

    var muted = appearance;

    muted.shadow = draw.rgba(0, 0, 0, 28);

    return muted;

}

pub fn clear(surface: *const Surface) void {

    surface.fill(draw.transparent);
    clear_effect(surface);

}

pub fn panel(surface: *const Surface, rect: Rect, appearance: Style) void {

    if (rect.is_empty()) return;

    bezel_field(surface, rect, appearance.radius, appearance.bezel, appearance.refraction);
    soft_shadow(surface, rect, appearance);
    draw.round.fill_round_rect(surface, rect, appearance.radius, appearance.fill);
    draw.round.stroke_round_rect_fast(surface, rect, appearance.radius, 1, panel_border);

}

pub fn control(surface: *const Surface, rect: Rect, appearance: Style, hovered: bool) void {

    const fill = if (hovered) appearance.control_hover else appearance.control;
    const opacity = if (hovered) appearance.control_hover_alpha else appearance.control_alpha;
    const radius = @min(12, @divTrunc(rect.h, 2));

    bezel_field(surface, rect, radius, control_bezel, control_refraction);
    draw.round.fill_round_rect_alpha(surface, rect, radius, fill, opacity);
    draw.round.stroke_round_rect_fast(surface, rect, radius, 1, control_border);

}

/// Turns an ordinary rounded UI fill into a Quartz sub-element when its surface carries an effect plane.
pub fn fill_element(surface: *const Surface, rect: Rect, radius: i32, tint: Color) bool {

    if (surface.format != .alpha or surface.effect == null) return false;
    if (draw.pixel_alpha(tint) != 255 or rect.is_empty()) return false;

    const visible = rect.intersect(surface.clip).intersect(surface.bounds());

    if (visible.is_empty()) return false;

    const sample_x = @max(visible.x, @min(rect.x + @divTrunc(rect.w, 2), visible.x + visible.w - 1));
    const sample_y = @max(visible.y, @min(rect.y + @divTrunc(rect.h, 2), visible.y + visible.h - 1));
    const sample_index = @as(usize, @intCast(sample_y)) * surface.stride + @as(usize, @intCast(sample_x));

    // An opaque backing means Quartz is disabled (or this is not inside its material).
    if (draw.pixel_alpha(surface.pixels[sample_index]) == 255) return false;

    bezel_field(surface, rect, radius, control_bezel, control_refraction);
    draw.round.fill_round_rect_alpha(surface, rect, radius, tint, element_opacity);

    return true;

}

fn soft_shadow(surface: *const Surface, rect: Rect, appearance: Style) void {

    const strength = draw.pixel_alpha(appearance.shadow);
    const falloff = [_]u8{ 3, 7, 14, 24, 36 };
    var spread: i32 = @intCast(falloff.len);

    while (spread >= 1) : (spread -= 1) {

        const index: usize = falloff.len - @as(usize, @intCast(spread));
        const opacity: u8 = @intCast((@as(u32, strength) * @as(u32, falloff[index]) + 32) / 64);
        const shadow_rect = rect.translated(0, 4).inset(-spread);

        draw.round.stroke_round_rect_fast(
            surface,
            shadow_rect,
            appearance.radius + spread,
            1,
            draw.with_alpha(draw.rgb(0, 0, 0), opacity),
        );

    }

}

fn clear_effect(surface: *const Surface) void {

    const effect = surface.effect orelse return;
    const bounds = surface.clip.intersect(surface.bounds());

    if (bounds.is_empty()) return;

    var y = bounds.y;

    while (y < bounds.y + bounds.h) : (y += 1) {

        const start = @as(usize, @intCast(y)) * surface.effect_stride + @as(usize, @intCast(bounds.x)) * 2;

        @memset(effect[start .. start + @as(usize, @intCast(bounds.w)) * 2], 0);

    }

}

// Convex bezel displacement for the compositor lens redraw.
// Direction is inward along the surface normal (magnifying lens sample).
fn bezel_field(surface: *const Surface, rect: Rect, radius: i32, bezel: i32, maximum: i32) void {

    const effect = surface.effect orelse return;
    const bounds = rect.intersect(surface.clip).intersect(surface.bounds());

    if (bounds.is_empty() or maximum <= 0 or bezel <= 0) return;

    const r = draw.round.clamp_radius(rect, radius);
    const masks = draw.round.masks_for(r);
    const strength = @min(maximum, max_fixed);
    const band = @min(bezel, @divTrunc(@min(rect.w, rect.h), 2));

    const outer = bounds;
    const inner = Rect{

        .x = rect.x + band,
        .y = rect.y + band,
        .w = @max(0, rect.w - 2 * band),
        .h = @max(0, rect.h - 2 * band),

    };

    var y = outer.y;

    while (y < outer.y + outer.h) : (y += 1) {

        const row = @as(usize, @intCast(y)) * surface.effect_stride;
        const skip_inner = y >= inner.y and y < inner.y + inner.h and inner.w > 0;
        var x = outer.x;

        while (x < outer.x + outer.w) {

            if (skip_inner and x >= inner.x and x < inner.x + inner.w) {

                x = inner.x + inner.w;

                continue;

            }

            const coverage = rounded_coverage(rect, r, masks, x, y);

            if (coverage == 0) {

                x += 1;

                continue;

            }

            const sample = edge_sample(rect, r, band, x, y);

            if (sample.dist >= band) {

                x += 1;

                continue;

            }

            const profile = circular_profile(band - sample.dist, band);
            const magnitude = @divTrunc(@as(i32, profile) * strength + 127, 255);
            const target_x = @divTrunc(-sample.nx * magnitude, 256);
            const target_y = @divTrunc(-sample.ny * magnitude, 256);
            const index = row + @as(usize, @intCast(x)) * 2;

            effect[index] = encode_component(blend_component(decode_component(effect[index]), target_x, coverage));
            effect[index + 1] = encode_component(blend_component(decode_component(effect[index + 1]), target_y, coverage));
            x += 1;

        }

    }

}

const EdgeSample = struct {

    dist: i32,
    nx: i32,
    ny: i32,

};

fn edge_sample(rect: Rect, radius: i32, bezel: i32, x: i32, y: i32) EdgeSample {

    const local_x = x - rect.x;
    const local_y = y - rect.y;
    const r = @max(radius, 1);
    const max_x = rect.w - 1;
    const max_y = rect.h - 1;

    if (local_x >= bezel and local_x <= max_x - bezel and local_y >= bezel and local_y <= max_y - bezel) {

        return .{ .dist = bezel, .nx = 0, .ny = 0 };

    }

    const in_left = local_x < r;
    const in_right = local_x > max_x - r;
    const in_top = local_y < r;
    const in_bottom = local_y > max_y - r;

    if ((in_left or in_right) and (in_top or in_bottom)) {

        const cx: i32 = if (in_left) r else max_x - r;
        const cy: i32 = if (in_top) r else max_y - r;
        const dx = local_x - cx;
        const dy = local_y - cy;
        const approx = approx_length(dx, dy);
        const dist = r - approx;

        if (approx == 0) {

            const nx: i32 = if (in_left) -256 else 256;
            const ny: i32 = if (in_top) -256 else 256;

            return .{ .dist = @max(0, dist), .nx = nx, .ny = ny };

        }

        return .{

            .dist = @max(0, dist),
            .nx = @divTrunc(dx * 256, approx),
            .ny = @divTrunc(dy * 256, approx),

        };

    }

    const left = local_x;
    const right = max_x - local_x;
    const top = local_y;
    const bottom = max_y - local_y;

    if (left <= right and left <= top and left <= bottom) {

        return .{ .dist = left, .nx = -256, .ny = 0 };

    }

    if (right <= top and right <= bottom) {

        return .{ .dist = right, .nx = 256, .ny = 0 };

    }

    if (top <= bottom) {

        return .{ .dist = top, .nx = 0, .ny = -256 };

    }

    return .{ .dist = bottom, .nx = 0, .ny = 256 };

}

// Convex bezel: circular lens curve with linear lift so mid-band still morphs.
fn circular_profile(from_edge: i32, bezel: i32) u8 {

    if (from_edge <= 0 or bezel <= 0) return 0;

    const t = @min(255, @divTrunc(from_edge * 255, bezel));
    const tt = @as(u32, @intCast(t));
    const t2 = (tt * tt + 127) / 255;
    const under = 255 - t2;
    const root = curve_table[under];
    const curved = 255 - @as(u32, root);
    // Stronger linear share → background wraps deeper into the panel.
    const mixed = (curved * 2 + tt * 2 + 2) / 4;

    return @intCast(@min(255, mixed));

}

fn isqrt_byte(value: u8) u8 {

    var low: u32 = 0;
    var high: u32 = 255;
    const target: u32 = value;

    while (low < high) {

        const mid = (low + high + 1) / 2;

        if ((mid * mid + 127) / 255 <= target) {

            low = mid;

        } else {

            high = mid - 1;

        }

    }

    return @intCast(low);

}

fn make_curve_table() [256]u8 {

    @setEvalBranchQuota(10_000);

    var table: [256]u8 = undefined;

    for (0..table.len) |value| {

        table[value] = isqrt_byte(@intCast(value));

    }

    return table;

}

fn rounded_coverage(rect: Rect, radius: i32, masks: ?draw.round.Masks, x: i32, y: i32) u8 {

    if (radius <= 1 or masks == null) return 255;

    const local_x = x - rect.x;
    const local_y = y - rect.y;

    if (local_x >= radius and local_x < rect.w - radius) return 255;
    if (local_y >= radius and local_y < rect.h - radius) return 255;

    const view = masks.?;
    const corner_x = if (local_x < radius) local_x else local_x - (rect.w - radius);
    const corner_y = if (local_y < radius) local_y else local_y - (rect.h - radius);
    const index: usize = @intCast(corner_y * radius + corner_x);

    if (local_y < radius) return if (local_x < radius) view.tl[index] else view.tr[index];

    return if (local_x < radius) view.bl[index] else view.br[index];

}

fn approx_length(x: i32, y: i32) i32 {

    const ax = abs_i32(x);
    const ay = abs_i32(y);

    return @max(ax, ay) + (@min(ax, ay) >> 1);

}

fn blend_component(current: i32, target: i32, coverage: u8) i32 {

    const inverse = 255 - @as(i32, coverage);

    return @divTrunc(current * inverse + target * @as(i32, coverage), 255);

}

fn decode_component(value: u8) i32 {

    return @as(i8, @bitCast(value));

}

fn encode_component(value: i32) u8 {

    return @bitCast(@as(i8, @intCast(@max(-127, @min(value, 127)))));

}

fn abs_i32(value: i32) i32 {

    return if (value < 0) -value else value;

}

test "Quartz bezel field peaks at the edge and clears the interior" {

    var pixels = [_]Color{draw.transparent} ** (48 * 48);
    var effect = [_]u8{0} ** (48 * 48 * 2);
    var surface = Surface.from_pixels_format(&pixels, 48, 48, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 96;

    const appearance = style(.regular, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255));

    clear(&surface);
    panel(&surface, .{ .x = 2, .y = 2, .w = 44, .h = 44 }, appearance);

    try std.testing.expectEqual(@as(u8, 0), effect[0]);

    const edge_x = decode_component(effect[24 * 96 + 3 * 2]);
    const mid_x = decode_component(effect[24 * 96 + 12 * 2]);
    const center_x = decode_component(effect[24 * 96 + 24 * 2]);

    try std.testing.expect(edge_x > 0);
    try std.testing.expect(edge_x > mid_x);
    try std.testing.expectEqual(@as(i32, 0), center_x);

    control(&surface, .{ .x = 16, .y = 16, .w = 16, .h = 12 }, appearance, false);

    try std.testing.expectEqual(@as(i32, 0), decode_component(effect[22 * 96 + 24 * 2]));

}

test "Quartz circular profile is monotonic from edge to interior" {

    try std.testing.expectEqual(@as(u8, 0), circular_profile(0, 16));
    try std.testing.expect(circular_profile(1, 16) < circular_profile(8, 16));
    try std.testing.expect(circular_profile(8, 16) < circular_profile(16, 16));
    try std.testing.expectEqual(@as(u8, 255), circular_profile(16, 16));

}

test "Quartz material densities darken without changing optical strength" {

    const clear_style = style(.clear, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255));
    const regular_style = style(.regular, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255));
    const prominent_style = style(.prominent, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255));

    try std.testing.expect(material_opacity(.clear) < material_opacity(.regular));
    try std.testing.expect(material_opacity(.regular) < material_opacity(.prominent));
    try std.testing.expectEqual(clear_style.refraction, regular_style.refraction);
    try std.testing.expectEqual(regular_style.refraction, prominent_style.refraction);

}

test "Quartz UI elements reuse the surface effect plane" {

    var pixels = [_]Color{draw.transparent} ** (32 * 24);
    var effect = [_]u8{0} ** (32 * 24 * 2);
    var surface = Surface.from_pixels_format(&pixels, 32, 24, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 64;

    try std.testing.expect(fill_element(&surface, .{ .x = 4, .y = 4, .w = 24, .h = 16 }, 6, draw.rgb(52, 52, 52)));
    try std.testing.expectEqual(element_opacity, draw.pixel_alpha(pixels[12 * 32 + 16]));

    var displaced = false;

    for (effect) |component| {

        if (component != 0) {

            displaced = true;
            break;

        }

    }

    try std.testing.expect(displaced);

    surface.fill(draw.rgb(30, 30, 30));
    @memset(effect[0..], 0);

    try std.testing.expect(!fill_element(&surface, .{ .x = 4, .y = 4, .w = 24, .h = 16 }, 6, draw.rgb(52, 52, 52)));

}
