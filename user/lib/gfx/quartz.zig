const std = @import("std");

const draw = @import("../draw/draw.zig");

const Color = draw.Color;
const Rect = draw.Rect;
const Surface = draw.Surface;

// Displacement is signed i8 in 1/16-pixel units.
const fixed_one: i32 = 16;
const max_fixed: i32 = 127;
const profile_slope_num: i32 = 11;
const profile_slope_den: i32 = 10;
const fold_margin_num: i32 = 15;
const fold_margin_den: i32 = 16;

pub const compositor_morph_gain_num: i32 = 13;
pub const compositor_morph_gain_den: i32 = 5;

// Wide convex bezel → background edges visibly wrap around the glass rim.
const bezel_width: i32 = 24;
const control_bezel: i32 = 12;
const control_refraction: i32 = max_fixed;
const axis_cache_limit: i32 = bezel_width;
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
        // Density leaves optical strength stable while the compositor varies frost and tint.
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

/// Draws a panel whose material continues through its top boundary.
pub fn panel_joined_top(surface: *const Surface, rect: Rect, appearance: Style) void {

    const overlap = @max(0, appearance.bezel);
    var joined = rect;

    joined.y -= overlap;
    joined.h += overlap;

    panel(surface, joined, appearance);

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

    if (strength == 0) return;

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

// Sample outward so strong rim displacement compresses detail instead of magnifying it into a caustic.
fn bezel_field(surface: *const Surface, rect: Rect, radius: i32, bezel: i32, maximum: i32) void {

    const effect = surface.effect orelse return;
    const bounds = rect.intersect(surface.clip).intersect(surface.bounds());

    if (bounds.is_empty() or maximum <= 0 or bezel <= 0) return;

    const r = draw.round.clamp_radius(rect, radius);
    const masks = draw.round.masks_for(r);
    const half = @divTrunc(@min(rect.w, rect.h), 2);
    const band = @min(bezel, @max(0, half - 1));

    if (band == 0) return;

    const strength = safe_refraction(@min(maximum, max_fixed), band);
    const axis = AxisProfile.init(band, strength);

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
        const local_y = y - rect.y;
        const bottom = rect.h - 1 - local_y;
        var target_y = -axis.component(@min(local_y, bottom));
        const skip_inner = y >= inner.y and y < inner.y + inner.h and inner.w > 0;
        var x = outer.x;

        if (bottom < local_y) target_y = -target_y;

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

            const local_x = x - rect.x;
            const right = rect.w - 1 - local_x;
            var target_x = -axis.component(@min(local_x, right));

            if (right < local_x) target_x = -target_x;

            const index = row + @as(usize, @intCast(x)) * 2;

            effect[index] = encode_component(blend_component(decode_component(effect[index]), target_x, coverage));
            effect[index + 1] = encode_component(blend_component(decode_component(effect[index + 1]), target_y, coverage));
            x += 1;

        }

    }

}

const AxisProfile = struct {

    band: i32,
    strength: i32,
    cached: bool,
    components: [axis_cache_limit]u8 = [_]u8{0} ** axis_cache_limit,

    fn init(band: i32, strength: i32) AxisProfile {

        var result = AxisProfile{

            .band = band,
            .strength = strength,
            .cached = band <= axis_cache_limit,

        };

        if (result.cached) {

            var distance: i32 = 0;

            while (distance < band) : (distance += 1) {

                result.components[@intCast(distance)] = @intCast(axis_component(distance, band, strength));

            }

        }

        return result;

    }

    inline fn component(self: *const AxisProfile, distance: i32) i32 {

        if (distance < 0 or distance >= self.band) return 0;
        if (!self.cached) return axis_component(distance, self.band, self.strength);

        return self.components[@intCast(distance)];

    }

};

inline fn axis_component(distance: i32, bezel: i32, strength: i32) i32 {

    if (distance < 0 or distance >= bezel) return 0;

    const bezel_fixed = bezel * fixed_one;
    const distance_fixed = distance * fixed_one + fixed_one / 2;
    const profile = lens_profile(bezel_fixed - distance_fixed, bezel_fixed);

    return @divTrunc(@as(i32, profile) * strength + 127, 255);

}

/// Caps ray travel to the span that can carry it without reversing the backdrop mapping.
pub inline fn safe_refraction(requested: i32, span: i32) i32 {

    if (requested <= 0 or span <= 0) return 0;

    const numerator = @as(i64, span) * fixed_one * compositor_morph_gain_den * profile_slope_den * fold_margin_num;
    const denominator: i64 = compositor_morph_gain_num * profile_slope_num * fold_margin_den;
    const safe = @divTrunc(numerator, denominator);

    return @intCast(@min(@as(i64, requested), safe));

}

/// Convex lens profile whose bounded derivative keeps adjacent backdrop rays ordered.
pub inline fn lens_profile(from_edge: i32, bezel: i32) u8 {

    if (from_edge <= 0 or bezel <= 0) return 0;

    const t = @min(255, @divTrunc(@as(i64, from_edge) * 255, bezel));
    const tt = @as(u32, @intCast(t));
    const t2 = (tt * tt + 127) / 255;
    const mixed = (tt * 9 + t2 + 5) / 10;

    return @intCast(@min(255, mixed));

}

inline fn rounded_coverage(rect: Rect, radius: i32, masks: ?draw.round.Masks, x: i32, y: i32) u8 {

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

test "Quartz bezel field peaks at the boundary and clears the interior" {

    var pixels = [_]Color{draw.transparent} ** (48 * 48);
    var effect = [_]u8{0} ** (48 * 48 * 2);
    var surface = Surface.from_pixels_format(&pixels, 48, 48, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 96;

    const appearance = style(.regular, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255));

    clear(&surface);
    panel(&surface, .{ .x = 2, .y = 2, .w = 44, .h = 44 }, appearance);

    try std.testing.expectEqual(@as(u8, 0), effect[0]);

    const boundary_x = decode_component(effect[24 * 96 + 2 * 2]);
    const edge_x = decode_component(effect[24 * 96 + 6 * 2]);
    const mid_x = decode_component(effect[24 * 96 + 14 * 2]);
    const center_x = decode_component(effect[24 * 96 + 24 * 2]);

    try std.testing.expect(boundary_x < edge_x);
    try std.testing.expect(edge_x < 0);
    try std.testing.expect(edge_x < mid_x);
    try std.testing.expectEqual(@as(i32, 0), center_x);

    control(&surface, .{ .x = 16, .y = 16, .w = 16, .h = 12 }, appearance, false);

    try std.testing.expectEqual(@as(i32, 0), decode_component(effect[22 * 96 + 24 * 2]));

}

test "Quartz lens profile is monotonic from edge to interior" {

    try std.testing.expectEqual(@as(u8, 0), lens_profile(0, 16));
    try std.testing.expect(lens_profile(1, 16) < lens_profile(8, 16));
    try std.testing.expect(lens_profile(8, 16) < lens_profile(16, 16));
    try std.testing.expectEqual(@as(u8, 255), lens_profile(16, 16));

}

test "Quartz boosted edge field keeps backdrop rays ordered" {

    const bezel: i32 = 24;
    const strength = safe_refraction(max_fixed, bezel);
    var previous = axis_component(0, bezel, strength);
    var distance: i32 = 1;

    try std.testing.expectEqual(max_fixed, strength);

    while (distance < bezel) : (distance += 1) {

        const current = axis_component(distance, bezel, strength);
        const encoded_drop = previous - current;

        try std.testing.expect(encoded_drop * compositor_morph_gain_num < fixed_one * compositor_morph_gain_den);

        previous = current;

    }

}

test "Quartz corner combines both ordered edge fields" {

    var pixels = [_]Color{draw.transparent} ** (64 * 64);
    var effect = [_]u8{0} ** (64 * 64 * 2);
    var surface = Surface.from_pixels_format(&pixels, 64, 64, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 128;

    panel(&surface, surface.bounds(), style(.regular, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255)));

    const index = 50 * surface.effect_stride + 50 * 2;

    try std.testing.expect(decode_component(effect[index]) > 0);
    try std.testing.expect(decode_component(effect[index + 1]) > 0);

}

test "Quartz joined panel leaves its top seam optically flat" {

    var pixels = [_]Color{draw.transparent} ** (64 * 64);
    var effect = [_]u8{0} ** (64 * 64 * 2);
    var surface = Surface.from_pixels_format(&pixels, 64, 64, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 128;

    panel_joined_top(&surface, surface.bounds(), style(.regular, draw.rgb(20, 20, 20), draw.rgb(64, 128, 255)));

    const top = 32 * 2 + 1;
    const bottom = 63 * surface.effect_stride + 32 * 2 + 1;
    const bottom_inner = 60 * surface.effect_stride + 32 * 2 + 1;

    try std.testing.expectEqual(@as(i32, 0), decode_component(effect[top]));
    try std.testing.expect(decode_component(effect[bottom]) > 0);
    try std.testing.expect(decode_component(effect[bottom_inner]) > 0);

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

/// Hovered/interactive Quartz sub-element
pub fn control_fill(surface: *const Surface, rect: Rect, radius: i32, tint: Color) bool {

    if (!fill_element(surface, rect, radius, tint)) return false;

    draw.round.stroke_round_rect_fast(surface, rect, radius, 1, control_border);

    return true;

}

test "Quartz control fill adds a rim only over live material" {

    var pixels = [_]Color{draw.transparent} ** (32 * 24);
    var effect = [_]u8{0} ** (32 * 24 * 2);
    var surface = Surface.from_pixels_format(&pixels, 32, 24, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 64;

    try std.testing.expect(control_fill(&surface, .{ .x = 4, .y = 4, .w = 24, .h = 16 }, 6, draw.rgb(52, 52, 52)));

    surface.fill(draw.rgb(30, 30, 30));

    try std.testing.expect(!control_fill(&surface, .{ .x = 4, .y = 4, .w = 24, .h = 16 }, 6, draw.rgb(52, 52, 52)));

}
