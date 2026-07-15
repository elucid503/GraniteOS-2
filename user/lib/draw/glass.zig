// Procedural "liquid glass" backdrop material: capture, box blur, and a rounded-rect signed
// distance field that drives both the anti-aliased edge coverage and the refraction (lens) offset
// from a single geometric source, so the shape can never show a seam between the two. Pure Surface
// math, no syscalls: the compositor owns capture/scratch buffer memory (main.zig) and calls into
// this module to fill them and to write the final result back.

const std = @import("std");

const draw_mod = @import("draw.zig");

const Color = draw_mod.Color;
const Rect = draw_mod.Rect;
const Surface = draw_mod.Surface;

/// A procedural material: every glass element (dock, popout, or anything else that opts in) is
/// fully described by one of these plus its own rounded-rect geometry. No bespoke per-widget code.
pub const Material = struct {

    // Backdrop softening: `blur_passes` box-blur passes of `blur_radius` px each (2-3 passes
    // approximate a Gaussian). Running-sum box blur is O(1) per pixel per pass.
    blur_radius: u8,
    blur_passes: u8,

    // Flat tint blended over the blurred backdrop, everywhere inside the shape.
    tint: Color,
    tint_alpha: u8,

    // Edge lensing: the backdrop displaces by up to `refraction` px near the boundary, ramping to
    // zero over `edge_width` px toward the interior. 0 refraction is a flat frosted pane.
    refraction: u8,
    edge_width: u8,

    // Specular bevel: a lit rim (top/left, facing a fixed light) and a shadowed rim (bottom/right),
    // both scaled by the same edge ramp as refraction.
    rim_light: u8,
    rim_shadow: u8,

};

/// The always-on-top dock/taskbar strip: a little more frosted, a little more tint (it sits over
/// arbitrary desktop content for the whole session).
pub const dock: Material = .{

    .blur_radius = 6,
    .blur_passes = 2,

    .tint = draw_mod.rgb(20, 20, 26),
    .tint_alpha = 60,

    .refraction = 3,
    .edge_width = 10,

    .rim_light = 46,
    .rim_shadow = 64,

};

/// Transient popouts (the launcher grid, calendar, weather card): slightly clearer, a touch more lens.
pub const panel: Material = .{

    .blur_radius = 6,
    .blur_passes = 2,

    .tint = draw_mod.rgb(22, 22, 28),
    .tint_alpha = 54,

    .refraction = 3,
    .edge_width = 9,

    .rim_light = 42,
    .rim_shadow = 58,

};

/// How far outside an element's own footprint a repaint must capture backdrop pixels from: the
/// blur reads `blur_radius` px per pass beyond the footprint, and refraction displaces samples by
/// up to `refraction` px on top of that. Callers dilate both the capture rect and glass-aware damage
/// by this amount so a partial repaint's blur/lens never runs out of real backdrop to read.
pub fn halo(material: Material) i32 {

    return @as(i32, material.blur_radius) * @as(i32, material.blur_passes) + @as(i32, material.refraction) + 1;

}

/// Captures the backdrop under `capture_rect` from `back`, blurs it, then for every pixel in
/// `footprint` (a sub-rect of `frame`, already clipped by the caller) samples the blurred backdrop
/// with a per-pixel lens offset and writes the tinted, beveled result back into `back` with
/// rounded-rect anti-aliased coverage. `capture` and `scratch` must already be sized to exactly
/// `capture_rect.w x capture_rect.h`; `scratch` is transient ping-pong storage for the blur passes.
pub fn render_backdrop(back: *const Surface, capture: *const Surface, scratch: *const Surface, capture_rect: Rect, frame: Rect, footprint: Rect, radius: i32, material: Material) void {

    const area = footprint.intersect(frame).intersect(back.bounds());

    if (area.is_empty() or capture_rect.is_empty()) return;
    if (capture.width != @as(u32, @intCast(capture_rect.w)) or capture.height != @as(u32, @intCast(capture_rect.h))) return;
    if (capture.width != scratch.width or capture.height != scratch.height) return;

    capture.blit(0, 0, back, capture_rect);

    var pass: u8 = 0;

    while (pass < material.blur_passes) : (pass += 1) {

        box_blur_horizontal(scratch, capture, material.blur_radius);
        box_blur_vertical(capture, scratch, material.blur_radius);

    }

    paint_shape(back, capture, capture_rect, frame, area, radius, material);

}

fn paint_shape(back: *const Surface, capture: *const Surface, capture_rect: Rect, frame: Rect, area: Rect, radius: i32, material: Material) void {

    const half_w: f32 = @as(f32, @floatFromInt(frame.w)) * 0.5;
    const half_h: f32 = @as(f32, @floatFromInt(frame.h)) * 0.5;
    const center_x: f32 = @as(f32, @floatFromInt(frame.x)) + half_w;
    const center_y: f32 = @as(f32, @floatFromInt(frame.y)) + half_h;

    const rf: f32 = @floatFromInt(radius);
    const edge_w: f32 = @floatFromInt(@max(@as(u8, 1), material.edge_width));
    const refraction: f32 = @floatFromInt(material.refraction);
    const capture_x: f32 = @floatFromInt(capture_rect.x);
    const capture_y: f32 = @floatFromInt(capture_rect.y);

    var y = area.y;

    while (y < area.y + area.h) : (y += 1) {

        var x = area.x;

        while (x < area.x + area.w) : (x += 1) {

            const shape = rounded_box_field(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, center_x, center_y, half_w, half_h, rf);

            // Beyond the anti-aliased fringe: fully outside the shape, leave whatever is beneath untouched.
            if (shape.dist > 0.75) continue;

            const coverage = shape_coverage(shape.dist);

            if (coverage == 0) continue;

            const ramp = std.math.clamp((shape.dist + edge_w) / edge_w, 0.0, 1.0);
            const mag = refraction * ramp;

            const sample_x = @as(f32, @floatFromInt(x)) + 0.5 + shape.nx * mag - capture_x;
            const sample_y = @as(f32, @floatFromInt(y)) + 0.5 + shape.ny * mag - capture_y;

            const sampled = sample_bilinear(capture, sample_x, sample_y);
            const tinted = draw_mod.mix(sampled, material.tint, material.tint_alpha);
            const shaded = apply_bevel(tinted, shape.nx, shape.ny, ramp, material);

            back.blend_pixel(x, y, shaded, coverage);

        }

    }

}

const ShapeField = struct {

    dist: f32,
    nx: f32,
    ny: f32,

};

/// Signed distance (negative inside) from a rounded-rect boundary, plus the outward unit normal at
/// that point. One formula drives both the anti-aliased edge and the refraction direction/ramp, so
/// the two can never disagree about where the shape's edge actually is.
fn rounded_box_field(px: f32, py: f32, center_x: f32, center_y: f32, half_w: f32, half_h: f32, radius: f32) ShapeField {

    const dx = px - center_x;
    const dy = py - center_y;

    const qx = @abs(dx) - (half_w - radius);
    const qy = @abs(dy) - (half_h - radius);

    if (qx > 0 and qy > 0) {

        const len = @sqrt(qx * qx + qy * qy);

        if (len < 0.0001) return .{ .dist = -radius, .nx = 0, .ny = 0 };

        return .{

            .dist = len - radius,
            .nx = (qx / len) * sign(dx),
            .ny = (qy / len) * sign(dy),

        };

    }

    if (qx >= qy) {

        return .{ .dist = qx - radius, .nx = sign(dx), .ny = 0 };

    }

    return .{ .dist = qy - radius, .nx = 0, .ny = sign(dy) };

}

fn sign(value: f32) f32 {

    if (value > 0) return 1;
    if (value < 0) return -1;

    return 0;

}

/// A 1.5px-wide anti-aliased ramp centered on the boundary: opaque well inside, transparent well outside.
fn shape_coverage(dist: f32) u8 {

    const coverage_f = std.math.clamp(0.5 - dist, 0.0, 1.0);

    return @intFromFloat(coverage_f * 255.0 + 0.5);

}

fn apply_bevel(color: Color, nx: f32, ny: f32, ramp: f32, material: Material) Color {

    if (ramp <= 0) return color;

    // A fixed light from the top-left; the bevel just reads off the same outward normal refraction uses.
    const bevel_dot = -(nx + ny) * 0.7071;

    if (bevel_dot > 0) {

        const amount_f = std.math.clamp(@as(f32, @floatFromInt(material.rim_light)) * ramp * bevel_dot, 0.0, 255.0);

        return draw_mod.mix(color, 0xffffff, @intFromFloat(amount_f));

    }

    if (bevel_dot < 0) {

        const amount_f = std.math.clamp(@as(f32, @floatFromInt(material.rim_shadow)) * ramp * -bevel_dot, 0.0, 255.0);

        return draw_mod.mix(color, 0x000000, @intFromFloat(amount_f));

    }

    return color;

}

fn sample_bilinear(surface: *const Surface, fx: f32, fy: f32) Color {

    const max_x: f32 = @floatFromInt(surface.width - 1);
    const max_y: f32 = @floatFromInt(surface.height - 1);

    const cx = std.math.clamp(fx, 0.0, max_x);
    const cy = std.math.clamp(fy, 0.0, max_y);

    const x0: u32 = @intFromFloat(@floor(cx));
    const y0: u32 = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, surface.width - 1);
    const y1 = @min(y0 + 1, surface.height - 1);

    const tx: u8 = @intFromFloat(std.math.clamp((cx - @floor(cx)) * 255.0 + 0.5, 0.0, 255.0));
    const ty: u8 = @intFromFloat(std.math.clamp((cy - @floor(cy)) * 255.0 + 0.5, 0.0, 255.0));

    const row0 = y0 * surface.stride;
    const row1 = y1 * surface.stride;

    const top = draw_mod.mix(surface.pixels[row0 + x0], surface.pixels[row0 + x1], tx);
    const bottom = draw_mod.mix(surface.pixels[row1 + x0], surface.pixels[row1 + x1], tx);

    return draw_mod.mix(top, bottom, ty);

}

/// Separable box blur, horizontal pass: O(1) per pixel via a running sum, edge-clamped.
fn box_blur_horizontal(dst: *const Surface, src: *const Surface, radius: u8) void {

    const w: i32 = @intCast(src.width);
    const h: i32 = @intCast(src.height);

    if (radius == 0 or w <= 0) {

        dst.blit(0, 0, src, src.bounds());

        return;

    }

    const r: i32 = radius;
    const window: u32 = @intCast(2 * r + 1);

    var y: i32 = 0;

    while (y < h) : (y += 1) {

        const row = @as(u32, @intCast(y)) * src.stride;
        const dst_row = @as(u32, @intCast(y)) * dst.stride;

        var r_sum: u32 = 0;
        var g_sum: u32 = 0;
        var b_sum: u32 = 0;

        var k: i32 = -r;

        while (k <= r) : (k += 1) {

            const cx: u32 = @intCast(std.math.clamp(k, 0, w - 1));
            const c = src.pixels[row + cx];

            r_sum += draw_mod.red(c);
            g_sum += draw_mod.green(c);
            b_sum += draw_mod.blue(c);

        }

        dst.pixels[dst_row] = draw_mod.rgb(@intCast(r_sum / window), @intCast(g_sum / window), @intCast(b_sum / window));

        var x: i32 = 1;

        while (x < w) : (x += 1) {

            const add_x: u32 = @intCast(std.math.clamp(x + r, 0, w - 1));
            const rem_x: u32 = @intCast(std.math.clamp(x - r - 1, 0, w - 1));

            const add_c = src.pixels[row + add_x];
            const rem_c = src.pixels[row + rem_x];

            r_sum = r_sum + draw_mod.red(add_c) - draw_mod.red(rem_c);
            g_sum = g_sum + draw_mod.green(add_c) - draw_mod.green(rem_c);
            b_sum = b_sum + draw_mod.blue(add_c) - draw_mod.blue(rem_c);

            dst.pixels[dst_row + @as(u32, @intCast(x))] = draw_mod.rgb(@intCast(r_sum / window), @intCast(g_sum / window), @intCast(b_sum / window));

        }

    }

}

/// Separable box blur, vertical pass: same running-sum shape as the horizontal pass, stepped by stride.
fn box_blur_vertical(dst: *const Surface, src: *const Surface, radius: u8) void {

    const w: i32 = @intCast(src.width);
    const h: i32 = @intCast(src.height);

    if (radius == 0 or h <= 0) {

        dst.blit(0, 0, src, src.bounds());

        return;

    }

    const r: i32 = radius;
    const window: u32 = @intCast(2 * r + 1);

    var x: i32 = 0;

    while (x < w) : (x += 1) {

        const col: u32 = @intCast(x);

        var r_sum: u32 = 0;
        var g_sum: u32 = 0;
        var b_sum: u32 = 0;

        var k: i32 = -r;

        while (k <= r) : (k += 1) {

            const cy: u32 = @intCast(std.math.clamp(k, 0, h - 1));
            const c = src.pixels[cy * src.stride + col];

            r_sum += draw_mod.red(c);
            g_sum += draw_mod.green(c);
            b_sum += draw_mod.blue(c);

        }

        dst.pixels[col] = draw_mod.rgb(@intCast(r_sum / window), @intCast(g_sum / window), @intCast(b_sum / window));

        var y: i32 = 1;

        while (y < h) : (y += 1) {

            const add_y: u32 = @intCast(std.math.clamp(y + r, 0, h - 1));
            const rem_y: u32 = @intCast(std.math.clamp(y - r - 1, 0, h - 1));

            const add_c = src.pixels[add_y * src.stride + col];
            const rem_c = src.pixels[rem_y * src.stride + col];

            r_sum = r_sum + draw_mod.red(add_c) - draw_mod.red(rem_c);
            g_sum = g_sum + draw_mod.green(add_c) - draw_mod.green(rem_c);
            b_sum = b_sum + draw_mod.blue(add_c) - draw_mod.blue(rem_c);

            dst.pixels[@as(u32, @intCast(y)) * dst.stride + col] = draw_mod.rgb(@intCast(r_sum / window), @intCast(g_sum / window), @intCast(b_sum / window));

        }

    }

}

const testing = std.testing;

test "halo grows with blur passes and refraction" {

    try testing.expectEqual(@as(i32, 6 * 2 + 3 + 1), halo(dock));
    try testing.expect(halo(panel) > 0);

}

test "box blur leaves a uniform field unchanged" {

    var a_buf: [16]u32 = [_]u32{0x336699} ** 16;
    var b_buf: [16]u32 = undefined;

    const a = Surface.from_pixels(&a_buf, 4, 4);
    const b = Surface.from_pixels(&b_buf, 4, 4);

    box_blur_horizontal(&b, &a, 2);
    box_blur_vertical(&a, &b, 2);

    for (a_buf) |pixel| try testing.expectEqual(@as(u32, 0x336699), pixel);

}

test "box blur spreads an impulse symmetrically" {

    var a_buf: [25]u32 = [_]u32{0} ** 25;
    var b_buf: [25]u32 = undefined;

    a_buf[2 * 5 + 2] = 0xffffff;

    const a = Surface.from_pixels(&a_buf, 5, 5);
    const b = Surface.from_pixels(&b_buf, 5, 5);

    box_blur_horizontal(&b, &a, 1);
    box_blur_vertical(&a, &b, 1);

    // The center row is symmetric around the impulse column, and the center pixel is the brightest.
    try testing.expectEqual(a_buf[2 * 5 + 1], a_buf[2 * 5 + 3]);
    try testing.expect(draw_mod.red(a_buf[2 * 5 + 2]) > draw_mod.red(a_buf[2 * 5 + 1]));
    try testing.expect(draw_mod.red(a_buf[2 * 5 + 2]) > 0);

}

test "render_backdrop tints the interior and leaves true corners untouched" {

    var back_buf: [40 * 40]u32 = [_]u32{0x808080} ** (40 * 40);
    const back = Surface.from_pixels(&back_buf, 40, 40);

    const frame = Rect{ .x = 4, .y = 4, .w = 32, .h = 32 };
    const radius: i32 = 8;

    var material = panel;

    material.refraction = 0;
    material.tint = 0xff0000;
    material.tint_alpha = 255;

    const h = halo(material);
    const capture_rect = frame.inset(-h).intersect(back.bounds());

    var capture_buf: [64 * 64]u32 = undefined;
    var scratch_buf: [64 * 64]u32 = undefined;

    const capture = Surface.from_pixels(&capture_buf, @intCast(capture_rect.w), @intCast(capture_rect.h));
    const scratch = Surface.from_pixels(&scratch_buf, @intCast(capture_rect.w), @intCast(capture_rect.h));

    render_backdrop(&back, &capture, &scratch, capture_rect, frame, frame, radius, material);

    // Deep interior: fully covered, fully tinted red.
    try testing.expectEqual(@as(u32, 0xff0000), back_buf[20 * 40 + 20]);

    // The literal corner of the frame is well outside the rounded shape (dist > 0.75): untouched.
    try testing.expectEqual(@as(u32, 0x808080), back_buf[4 * 40 + 4]);

}
