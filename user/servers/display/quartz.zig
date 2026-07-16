const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const draw = lib.draw;
const sys = lib.sys;

const Color = draw.Color;
const Handle = cap.Handle;
const Rect = draw.Rect;
const Surface = draw.Surface;

// Quartz captures an intact backdrop, builds a compact frost image, then resolves distortion, wavelength dispersion, rim clarity, and material in one full-size pass.

const coordinate_bits: u5 = 4;
const coordinate_one: i32 = 1 << coordinate_bits;
const max_refraction: i32 = 15;

// Extra stretch on encoded D so bezel morph reads clearly.
const morph_gain_num: i32 = 9;
const morph_gain_den: i32 = 5;

// Peak RGB split along the surface normal (fixed 1/16 px). ~2px at full rim.
const chroma_peak: i32 = coordinate_one * 2;
const chroma_gate: i32 = 28;
const blur_radius: i32 = 4;
const frost_scale: i32 = 2;
const frost_blur_radius: i32 = 2;
const frost_blur_count: u32 = frost_blur_radius * 2 + 1;
const header_bezel: i32 = 6;
const header_refraction: i32 = coordinate_one * 3;
const header_shift_pixels: i32 = @divTrunc(header_refraction * morph_gain_num, morph_gain_den * coordinate_one);

// How hard the sharp rim wins back over frost (0..255).
const rim_clarity: u8 = 168;
const mask_floor: u8 = 8;
const mask_ceiling: u8 = 72;
const color_mask: Color = 0x00ff_ffff;

pub const damage_halo: i32 = max_refraction + (chroma_peak / coordinate_one) + blur_radius + 1;
pub const header_damage_halo: i32 = header_shift_pixels + (chroma_peak / coordinate_one) + blur_radius + 1;

// Cursor-proximity rim light: the glass edge nearest the pointer brightens slightly.
pub const highlight_radius: i32 = 56;
const highlight_strength: u8 = 40;
const highlight_color: Color = 0x00ff_ffff;

const PixelSum = struct {

    red: u32 = 0,
    green: u32 = 0,
    blue: u32 = 0,

    inline fn add(self: *PixelSum, color: Color) void {

        self.red += draw.red(color);
        self.green += draw.green(color);
        self.blue += draw.blue(color);

    }

    inline fn remove(self: *PixelSum, color: Color) void {

        self.red -= draw.red(color);
        self.green -= draw.green(color);
        self.blue -= draw.blue(color);

    }

    inline fn average_frost(self: PixelSum) Color {

        return draw.rgb(
            average_frost_channel(self.red),
            average_frost_channel(self.green),
            average_frost_channel(self.blue),
        );

    }

};

const SampleRay = struct {

    x: i32 = 0,
    y: i32 = 0,
    // 0 interior .. 255 outer bezel (from |D|).
    rim: u8 = 0,
    nx: i32 = 0,
    ny: i32 = 0,

};

const output_cache_capacity = 128;

const OutputCache = struct {

    valid: bool = false,
    window: u32 = 0,
    content: Rect = Rect.empty,
    visible: Rect = Rect.empty,

};

pub const Renderer = struct {

    region: Handle = 0,
    base: usize = 0,

    width: u32 = 0,
    height: u32 = 0,

    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    highlight: bool = false,

    scene: [*]Color = undefined,
    lens: [*]Color = undefined,
    temp: [*]Color = undefined,
    scratch: [*]Color = undefined,

    output_cache: [output_cache_capacity]OutputCache = [_]OutputCache{.{}} ** output_cache_capacity,

    pub fn resize(self: *Renderer, width: u32, height: u32) !void {

        self.release();

        if (width == 0 or height == 0) return error.Invalid;

        const pixel_count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.TooLarge;
        const plane_bytes = std.math.mul(usize, pixel_count, @sizeOf(Color)) catch return error.TooLarge;
        const scale: usize = @intCast(frost_scale);
        const frost_width = (@as(usize, width) + scale - 1) / scale;
        const frost_height = (@as(usize, height) + scale - 1) / scale;
        const frost_pixels = std.math.mul(usize, frost_width, frost_height) catch return error.TooLarge;
        const frost_bytes = std.math.mul(usize, frost_pixels, @sizeOf(Color)) catch return error.TooLarge;
        const compact_bytes = std.math.mul(usize, frost_bytes, 2) catch return error.TooLarge;
        const bytes = std.math.add(usize, std.math.mul(usize, plane_bytes, 2) catch return error.TooLarge, compact_bytes) catch return error.TooLarge;

        const region = try sys.create(.region, bytes, cap.memory);
        const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch |failure| {

            sys.close(region) catch {};

            return failure;

        };

        const scene: [*]Color = @ptrFromInt(base);
        self.* = .{

            .region = region,
            .base = base,

            .width = width,
            .height = height,

            .scene = scene,
            .lens = scene + pixel_count,
            .temp = scene + pixel_count * 2,
            .scratch = scene + pixel_count * 2 + frost_pixels,

        };

    }

    pub fn release(self: *Renderer) void {

        if (self.base != 0) sys.unmap(cap.self_space, self.base) catch {};
        if (self.region != 0) sys.close(self.region) catch {};

        self.* = .{};

    }

    pub fn ready(self: *const Renderer) bool {

        return self.base != 0;

    }

    pub fn invalidate(self: *Renderer) void {

        for (&self.output_cache) |*entry| entry.valid = false;

    }

    pub fn invalidate_region(self: *Renderer, rect: Rect) void {

        if (rect.is_empty()) return;

        for (&self.output_cache) |*entry| {

            if (entry.valid and !entry.visible.intersect(rect).is_empty()) entry.valid = false;

        }

    }

    /// Record the pointer so the resolve passes can light the rim nearest it. `enabled` off => no highlight.
    pub fn set_cursor(self: *Renderer, x: i32, y: i32, enabled: bool) void {

        self.cursor_x = x;
        self.cursor_y = y;
        self.highlight = enabled;

    }

    // 0..highlight_strength: how much the rim at (x, y) leans toward white, by pointer distance and edge sharpness.
    inline fn highlight_amount(self: *const Renderer, x: i32, y: i32, rim: u8) u8 {

        if (!self.highlight or rim == 0) return 0;

        const dx = abs_axis(x - self.cursor_x);
        const dy = abs_axis(y - self.cursor_y);

        if (dx >= highlight_radius or dy >= highlight_radius) return 0;

        const dist = normal_denominator(dx, dy);

        if (dist >= highlight_radius) return 0;

        const proximity: u32 = @intCast(@divTrunc((highlight_radius - dist) * 255, highlight_radius));
        const gated = proximity * square_byte(rim) / 255;

        return @intCast(gated * highlight_strength / 255);

    }

    pub fn composite(self: *Renderer, back: *const Surface, foreground: *const Surface, content: Rect, clip: Rect, window: u32) bool {

        if (self.base == 0 or foreground.format != .alpha) return false;
        if (self.width != back.width or self.height != back.height) return false;

        const available = Rect{

            .x = content.x,
            .y = content.y,
            .w = @intCast(foreground.width),
            .h = @intCast(foreground.height),

        };

        const visible = available.intersect(content).intersect(clip).intersect(back.bounds());

        if (visible.is_empty()) return true;

        const scene_rect = visible.inset(-damage_halo).intersect(back.bounds());

        if (self.output_reusable(window, content, visible)) {

            self.blit_cached(back, visible);

            return true;

        }

        self.invalidate_output_overlap(visible);

        self.capture_scene(back, scene_rect);
        const frost_bounds = self.build_frost(scene_rect);

        self.resolve_compact(back, foreground, content, visible, scene_rect, frost_bounds);

        self.store_output_cache(window, content, visible);

        return true;

    }

    pub fn composite_header(self: *Renderer, back: *const Surface, content: Rect, clip: Rect, window: u32, tint: Color, opacity: u8, radius: i32) bool {

        if (self.base == 0 or opacity == 0) return false;
        if (self.width != back.width or self.height != back.height) return false;

        const visible = content.intersect(clip).intersect(back.bounds());

        if (visible.is_empty()) return true;

        const scene_rect = visible.inset(-header_damage_halo).intersect(back.bounds());
        const cache_key = window ^ 0x8000_0000;

        if (self.output_reusable(cache_key, content, visible)) {

            self.blit_cached(back, visible);

            return true;

        }

        self.invalidate_output_overlap(visible);

        self.capture_scene(back, scene_rect);
        const frost_bounds = self.build_frost(scene_rect);

        self.resolve_header(back, content, visible, scene_rect, frost_bounds, tint, opacity, radius);

        self.store_output_cache(cache_key, content, visible);

        return true;

    }

    fn output_reusable(self: *const Renderer, window: u32, content: Rect, visible: Rect) bool {

        for (self.output_cache) |entry| {

            if (!entry.valid or entry.window != window) continue;
            if (!rect_equal(entry.content, content)) continue;
            if (rect_covers(entry.visible, visible)) return true;

        }

        return false;

    }

    fn invalidate_output_overlap(self: *Renderer, visible: Rect) void {

        for (&self.output_cache) |*entry| {

            if (entry.valid and !entry.visible.intersect(visible).is_empty()) entry.valid = false;

        }

    }

    fn store_output_cache(self: *Renderer, window: u32, content: Rect, visible: Rect) void {

        for (&self.output_cache) |*entry| {

            if (entry.valid) continue;

            entry.* = .{

                .valid = true,
                .window = window,
                .content = content,
                .visible = visible,

            };

            return;

        }

        const index = @as(usize, window) % self.output_cache.len;

        self.output_cache[index] = .{

            .valid = true,
            .window = window,
            .content = content,
            .visible = visible,

        };

    }

    fn capture_scene(self: *Renderer, back: *const Surface, rect: Rect) void {

        var y = rect.y;

        while (y < rect.y + rect.h) : (y += 1) {

            const source_start = @as(usize, @intCast(y)) * back.stride + @as(usize, @intCast(rect.x));
            const destination_start = self.pixel_index(rect.x, y);
            const count: usize = @intCast(rect.w);

            @memcpy(self.scene[destination_start .. destination_start + count], back.pixels[source_start .. source_start + count]);

        }

    }

    fn build_frost(self: *Renderer, scene_rect: Rect) Rect {

        const rect = frost_rect(scene_rect);

        self.downsample_scene(scene_rect, rect);
        self.blur_frost_horizontal(self.temp, self.scratch, rect);
        self.blur_frost_vertical(self.scratch, self.temp, rect);

        return rect;

    }

    fn downsample_scene(self: *Renderer, scene_rect: Rect, rect: Rect) void {

        const max_x = scene_rect.x + scene_rect.w - 1;
        const max_y = scene_rect.y + scene_rect.h - 1;
        var y = rect.y;

        while (y < rect.y + rect.h) : (y += 1) {

            const source_y = clamp_axis(y * frost_scale, scene_rect.y, max_y);
            const next_y = @min(source_y + 1, max_y);
            var x = rect.x;

            while (x < rect.x + rect.w) : (x += 1) {

                const source_x = clamp_axis(x * frost_scale, scene_rect.x, max_x);
                const next_x = @min(source_x + 1, max_x);

                self.temp[self.frost_index(x, y)] = average_four(
                    self.scene[self.pixel_index(source_x, source_y)],
                    self.scene[self.pixel_index(next_x, source_y)],
                    self.scene[self.pixel_index(source_x, next_y)],
                    self.scene[self.pixel_index(next_x, next_y)],
                );

            }

        }

    }

    fn blur_frost_horizontal(self: *Renderer, source: [*]const Color, destination: [*]Color, rect: Rect) void {

        const min_x = rect.x;
        const max_x = rect.x + rect.w - 1;
        const max_y = rect.y + rect.h - 1;
        var y = rect.y;

        while (y <= max_y) : (y += 1) {

            var sum = PixelSum{};
            var offset = -frost_blur_radius;

            while (offset <= frost_blur_radius) : (offset += 1) {

                sum.add(source[self.frost_index(clamp_axis(min_x + offset, min_x, max_x), y)]);

            }

            var x = min_x;

            while (x <= max_x) : (x += 1) {

                destination[self.frost_index(x, y)] = sum.average_frost();

                const leaving_x = clamp_axis(x - frost_blur_radius, min_x, max_x);
                const entering_x = clamp_axis(x + frost_blur_radius + 1, min_x, max_x);

                sum.remove(source[self.frost_index(leaving_x, y)]);
                sum.add(source[self.frost_index(entering_x, y)]);

            }

        }

    }

    fn blur_frost_vertical(self: *Renderer, source: [*]const Color, destination: [*]Color, rect: Rect) void {

        const min_y = rect.y;
        const max_x = rect.x + rect.w - 1;
        const max_y = rect.y + rect.h - 1;
        var x = rect.x;

        while (x <= max_x) : (x += 1) {

            var sum = PixelSum{};
            var offset = -frost_blur_radius;

            while (offset <= frost_blur_radius) : (offset += 1) {

                sum.add(source[self.frost_index(x, clamp_axis(min_y + offset, min_y, max_y))]);

            }

            var y = min_y;

            while (y <= max_y) : (y += 1) {

                destination[self.frost_index(x, y)] = sum.average_frost();

                const leaving_y = clamp_axis(y - frost_blur_radius, min_y, max_y);
                const entering_y = clamp_axis(y + frost_blur_radius + 1, min_y, max_y);

                sum.remove(source[self.frost_index(x, leaving_y)]);
                sum.add(source[self.frost_index(x, entering_y)]);

            }

        }

    }

    // One glass ray: magnified offset from D, optional RGB dispersion near the rim.
    inline fn trace_glass(self: *const Renderer, ray: SampleRay, scene_rect: Rect) Color {

        const center = self.sample_scene(ray.x, ray.y, scene_rect);

        if (ray.rim < chroma_gate) return center;

        // Dispersion grows with surface curvature; blue bends farther than red.
        const chroma_weight = square_byte(ray.rim);

        if (chroma_weight < 8) return center;

        const chroma_mag = @divTrunc(@as(i32, chroma_weight) * chroma_peak, 255);
        const chroma_x = @divTrunc(ray.nx * chroma_mag, 256);
        const chroma_y = @divTrunc(ray.ny * chroma_mag, 256);

        const red_s = self.sample_scene(ray.x - chroma_x, ray.y - chroma_y, scene_rect);
        const blue_s = self.sample_scene(ray.x + chroma_x, ray.y + chroma_y, scene_rect);

        // Bake dispersion into a single lens color — not a post on the live buffer.
        return draw.rgb(draw.red(red_s), draw.green(center), draw.blue(blue_s));

    }

    inline fn ray_from_displacement(self: *const Renderer, x: i32, y: i32, displacement: Displacement) SampleRay {

        _ = self;

        var ray = SampleRay{

            .x = x * coordinate_one,
            .y = y * coordinate_one,

        };

        const shift_x = clamp_axis(
            @divTrunc(displacement.x * morph_gain_num, morph_gain_den),
            -max_refraction * coordinate_one,
            max_refraction * coordinate_one,
        );
        const shift_y = clamp_axis(
            @divTrunc(displacement.y * morph_gain_num, morph_gain_den),
            -max_refraction * coordinate_one,
            max_refraction * coordinate_one,
        );

        ray.x += shift_x;
        ray.y += shift_y;

        const denom = normal_denominator(shift_x, shift_y);

        if (denom == 0) return ray;

        ray.rim = rim_amount(denom);
        ray.nx = @divTrunc(shift_x * 256, denom);
        ray.ny = @divTrunc(shift_y * 256, denom);

        return ray;

    }

    fn resolve_compact(self: *Renderer, back: *const Surface, foreground: *const Surface, content: Rect, visible: Rect, scene_rect: Rect, frost_bounds: Rect) void {

        var y = visible.y;

        while (y < visible.y + visible.h) : (y += 1) {

            const source_y: u32 = @intCast(y - content.y);
            const row = source_y * foreground.stride;
            var x = visible.x;

            while (x < visible.x + visible.w) : (x += 1) {

                const source_x: u32 = @intCast(x - content.x);
                const source = foreground.pixels[row + source_x];
                const opacity = draw.pixel_alpha(source);
                const destination_index = @as(usize, @intCast(y)) * back.stride + @as(usize, @intCast(x));
                const cache_index = self.pixel_index(x, y);
                const original = back.pixels[destination_index];
                var resolved = original;

                if (opacity == 255) {

                    resolved = source;

                } else if (opacity != 0 and !is_material(source)) {

                    resolved = draw.composite_premultiplied(original, source);

                } else if (opacity != 0) {

                    const displacement = optical_displacement(foreground, @intCast(source_x), @intCast(source_y));
                    const ray = self.ray_from_displacement(x, y, displacement);
                    var optical = self.sample_frost(ray.x, ray.y, frost_bounds);

                    if (ray.rim >= chroma_gate) {

                        const sharp = self.trace_glass(ray, scene_rect);
                        const clarity = scale_byte(square_byte(ray.rim), rim_clarity);

                        optical = draw.mix(optical, sharp, clarity);

                    }

                    resolved = draw.composite_premultiplied(optical, source);

                    const glow = self.highlight_amount(x, y, ray.rim);

                    if (glow > 0) resolved = draw.mix(resolved, highlight_color, glow);

                }

                self.lens[cache_index] = resolved;
                back.pixels[destination_index] = resolved;

            }

        }

    }

    fn resolve_header(self: *Renderer, back: *const Surface, content: Rect, visible: Rect, scene_rect: Rect, frost_bounds: Rect, tint: Color, opacity: u8, radius: i32) void {

        const material = draw.with_alpha(tint, opacity);
        const r = draw.round.clamp_radius(content, radius);
        const masks = draw.round.masks_for(r);
        var y = visible.y;

        while (y < visible.y + visible.h) : (y += 1) {

            var x = visible.x;

            while (x < visible.x + visible.w) : (x += 1) {

                const destination_index = @as(usize, @intCast(y)) * back.stride + @as(usize, @intCast(x));
                const cache_index = self.pixel_index(x, y);
                const coverage = header_coverage(content, x, y, r, masks);
                const original = back.pixels[destination_index];
                const displacement = header_displacement(content, x, y);
                const ray = self.ray_from_displacement(x, y, displacement);
                var optical = self.sample_frost(ray.x, ray.y, frost_bounds);

                if (ray.rim >= chroma_gate) {

                    const sharp = self.trace_glass(ray, scene_rect);
                    const clarity = scale_byte(square_byte(ray.rim), rim_clarity);

                    optical = draw.mix(optical, sharp, clarity);

                }

                const glass = draw.composite_premultiplied(optical, material);
                var resolved = draw.mix(original, glass, coverage);

                const glow = self.highlight_amount(x, y, ray.rim);

                if (glow > 0) resolved = draw.mix(resolved, highlight_color, scale_byte(glow, coverage));

                self.lens[cache_index] = resolved;
                back.pixels[destination_index] = resolved;

            }

        }

    }

    fn blit_cached(self: *const Renderer, back: *const Surface, rect: Rect) void {

        var y = rect.y;

        while (y < rect.y + rect.h) : (y += 1) {

            const source_start = self.pixel_index(rect.x, y);
            const destination_start = @as(usize, @intCast(y)) * back.stride + @as(usize, @intCast(rect.x));
            const count: usize = @intCast(rect.w);

            @memcpy(back.pixels[destination_start .. destination_start + count], self.lens[source_start .. source_start + count]);

        }

    }

    inline fn sample_scene(self: *const Renderer, x_fixed: i32, y_fixed: i32, scene_rect: Rect) Color {

        const min_x = scene_rect.x;
        const min_y = scene_rect.y;
        const max_x = scene_rect.x + scene_rect.w - 1;
        const max_y = scene_rect.y + scene_rect.h - 1;
        const x = clamp_axis(@divFloor(x_fixed, coordinate_one), min_x, max_x);
        const y = clamp_axis(@divFloor(y_fixed, coordinate_one), min_y, max_y);
        const next_x = @min(x + 1, max_x);
        const next_y = @min(y + 1, max_y);
        const fraction_x = fixed_fraction(x_fixed, x, min_x, max_x);
        const fraction_y = fixed_fraction(y_fixed, y, min_y, max_y);

        if (fraction_x == 0 and fraction_y == 0) return self.scene[self.pixel_index(x, y)] & color_mask;

        return bilinear_color(
            self.scene[self.pixel_index(x, y)],
            self.scene[self.pixel_index(next_x, y)],
            self.scene[self.pixel_index(x, next_y)],
            self.scene[self.pixel_index(next_x, next_y)],
            fraction_x,
            fraction_y,
        );

    }

    inline fn sample_frost(self: *const Renderer, x_fixed: i32, y_fixed: i32, rect: Rect) Color {

        const low_x_fixed = @divFloor(x_fixed - coordinate_one / 2, frost_scale);
        const low_y_fixed = @divFloor(y_fixed - coordinate_one / 2, frost_scale);
        const min_x = rect.x;
        const min_y = rect.y;
        const max_x = rect.x + rect.w - 1;
        const max_y = rect.y + rect.h - 1;
        const x = clamp_axis(@divFloor(low_x_fixed, coordinate_one), min_x, max_x);
        const y = clamp_axis(@divFloor(low_y_fixed, coordinate_one), min_y, max_y);
        const next_x = @min(x + 1, max_x);
        const next_y = @min(y + 1, max_y);
        const fraction_x = fixed_fraction(low_x_fixed, x, min_x, max_x);
        const fraction_y = fixed_fraction(low_y_fixed, y, min_y, max_y);

        if (fraction_x == 0 and fraction_y == 0) return self.temp[self.frost_index(x, y)] & color_mask;

        return bilinear_color(
            self.temp[self.frost_index(x, y)],
            self.temp[self.frost_index(next_x, y)],
            self.temp[self.frost_index(x, next_y)],
            self.temp[self.frost_index(next_x, next_y)],
            fraction_x,
            fraction_y,
        );

    }

    inline fn pixel_index(self: *const Renderer, x: i32, y: i32) usize {

        return @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));

    }

    inline fn frost_index(self: *const Renderer, x: i32, y: i32) usize {

        const scale: usize = @intCast(frost_scale);
        const width = (@as(usize, self.width) + scale - 1) / scale;

        return @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));

    }

};

fn frost_rect(rect: Rect) Rect {

    const right = rect.x + rect.w;
    const bottom = rect.y + rect.h;
    const x = @divFloor(rect.x, frost_scale);
    const y = @divFloor(rect.y, frost_scale);

    return .{

        .x = x,
        .y = y,
        .w = @divFloor(right + frost_scale - 1, frost_scale) - x,
        .h = @divFloor(bottom + frost_scale - 1, frost_scale) - y,

    };

}

inline fn average_four(top_left: Color, top_right: Color, bottom_left: Color, bottom_right: Color) Color {

    return draw.rgb(
        @intCast((@as(u32, draw.red(top_left)) + draw.red(top_right) + draw.red(bottom_left) + draw.red(bottom_right) + 2) >> 2),
        @intCast((@as(u32, draw.green(top_left)) + draw.green(top_right) + draw.green(bottom_left) + draw.green(bottom_right) + 2) >> 2),
        @intCast((@as(u32, draw.blue(top_left)) + draw.blue(top_right) + draw.blue(bottom_left) + draw.blue(bottom_right) + 2) >> 2),
    );

}

inline fn header_coverage(content: Rect, x: i32, y: i32, radius: i32, masks: ?draw.round.Masks) u8 {

    if (radius <= 1 or y - content.y >= radius) return 255;

    const local_x = x - content.x;
    const local_y = y - content.y;

    if (local_x >= radius and local_x < content.w - radius) return 255;

    const available = masks orelse return 255;
    const row = @as(usize, @intCast(local_y)) * @as(usize, @intCast(radius));

    if (local_x < radius) return available.tl[row + @as(usize, @intCast(local_x))];

    const corner_x = local_x - (content.w - radius);

    return available.tr[row + @as(usize, @intCast(corner_x))];

}

const Displacement = struct {

    x: i32 = 0,
    y: i32 = 0,

};

inline fn header_displacement(rect: Rect, x: i32, y: i32) Displacement {

    const local_x = x - rect.x;
    const local_y = y - rect.y;
    const right = rect.w - 1 - local_x;
    const bottom = rect.h - 1 - local_y;
    var displacement = Displacement{};

    if (local_x < header_bezel) displacement.x += header_profile(local_x);
    if (right < header_bezel) displacement.x -= header_profile(right);
    if (local_y < header_bezel) displacement.y += header_profile(local_y);
    if (bottom < header_bezel) displacement.y -= header_profile(bottom);

    return displacement;

}

inline fn header_profile(distance: i32) i32 {

    const remaining = header_bezel - @max(0, distance);

    return @divTrunc(remaining * remaining * header_refraction, header_bezel * header_bezel);

}

inline fn optical_displacement(surface: *const Surface, x: i32, y: i32) Displacement {

    if (x < 0 or y < 0) return .{};
    if (x >= @as(i32, @intCast(surface.width)) or y >= @as(i32, @intCast(surface.height))) return .{};

    if (surface.effect) |effect| {

        const index = @as(usize, @intCast(y)) * surface.effect_stride + @as(usize, @intCast(x)) * 2;

        return .{

            .x = @as(i8, @bitCast(effect[index])),
            .y = @as(i8, @bitCast(effect[index + 1])),

        };

    }

    return .{};

}

inline fn is_material(color: Color) bool {

    if ((color & color_mask) == 0) return false;

    return mask_value(draw.pixel_alpha(color)) > 0;

}

inline fn mask_value(opacity: u8) u8 {

    if (opacity <= mask_floor) return 0;
    if (opacity >= mask_ceiling) return 255;

    const range = @as(u32, mask_ceiling - mask_floor);
    const value = @as(u32, opacity - mask_floor);

    return @intCast((value * 255 + range / 2) / range);

}

inline fn normal_denominator(x: i32, y: i32) i32 {

    const ax = abs_axis(x);
    const ay = abs_axis(y);

    return @max(ax, ay) + (@min(ax, ay) >> 1);

}

// |D| in fixed units → 0..255. Peak morph (~15px * 16) saturates the outer bezel.
inline fn rim_amount(slope: i32) u8 {

    return @intCast(clamp_axis(@divTrunc(slope * 255, max_refraction * coordinate_one), 0, 255));

}

inline fn scale_byte(value: u8, amount: u8) u8 {

    return @intCast((@as(u32, value) * amount + 127) / 255);

}

inline fn average_frost_channel(sum: u32) u8 {

    comptime if (frost_blur_count != 5) @compileError("update the Quartz frost reciprocal for the new radius");

    return @intCast(((sum + frost_blur_count / 2) * 52429) >> 18);

}

inline fn square_byte(value: u8) u8 {

    return scale_byte(value, value);

}

inline fn fixed_fraction(fixed: i32, cell: i32, min_cell: i32, max_cell: i32) u32 {

    if (cell == min_cell and fixed < min_cell * coordinate_one) return 0;
    if (cell == max_cell) return 0;

    return @intCast(@mod(fixed, coordinate_one));

}

inline fn clamp_axis(value: i32, minimum: i32, maximum: i32) i32 {

    return @max(minimum, @min(value, maximum));

}

inline fn abs_axis(value: i32) i32 {

    return if (value < 0) -value else value;

}

fn rect_equal(a: Rect, b: Rect) bool {

    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;

}

fn rect_covers(outer: Rect, inner: Rect) bool {

    if (outer.is_empty() or inner.is_empty()) return false;

    return outer.x <= inner.x and outer.y <= inner.y and outer.x + outer.w >= inner.x + inner.w and outer.y + outer.h >= inner.y + inner.h;

}

inline fn bilinear_color(top_left: Color, top_right: Color, bottom_left: Color, bottom_right: Color, fraction_x: u32, fraction_y: u32) Color {

    return draw.rgb(
        bilinear_channel(draw.red(top_left), draw.red(top_right), draw.red(bottom_left), draw.red(bottom_right), fraction_x, fraction_y),
        bilinear_channel(draw.green(top_left), draw.green(top_right), draw.green(bottom_left), draw.green(bottom_right), fraction_x, fraction_y),
        bilinear_channel(draw.blue(top_left), draw.blue(top_right), draw.blue(bottom_left), draw.blue(bottom_right), fraction_x, fraction_y),
    );

}

inline fn bilinear_channel(top_left: u8, top_right: u8, bottom_left: u8, bottom_right: u8, fraction_x: u32, fraction_y: u32) u8 {

    const scale: u32 = coordinate_one;
    const inverse_x = scale - fraction_x;
    const inverse_y = scale - fraction_y;
    const top = @as(u32, top_left) * inverse_x + @as(u32, top_right) * fraction_x;
    const bottom = @as(u32, bottom_left) * inverse_x + @as(u32, bottom_right) * fraction_x;
    const rounding: u32 = 1 << (coordinate_bits * 2 - 1);

    return @intCast((top * inverse_y + bottom * fraction_y + rounding) >> (coordinate_bits * 2));

}

test "Quartz mask keeps shadows out of the lens path" {

    try std.testing.expectEqual(@as(u8, 0), mask_value(mask_floor));
    try std.testing.expectEqual(@as(u8, 255), mask_value(mask_ceiling));
    try std.testing.expectEqual(@as(u8, 128), mask_value(mask_floor + (mask_ceiling - mask_floor) / 2));
    try std.testing.expect(!is_material(draw.with_alpha(draw.rgb(0, 0, 0), 64)));
    try std.testing.expect(is_material(draw.with_alpha(draw.rgb(32, 32, 32), 32)));

}

test "Quartz subpixel sampler interpolates every color channel" {

    const color = bilinear_color(
        draw.rgb(0, 0, 0),
        draw.rgb(255, 0, 0),
        draw.rgb(0, 255, 0),
        draw.rgb(0, 0, 255),
        coordinate_one / 2,
        coordinate_one / 2,
    );

    try std.testing.expectEqual(draw.rgb(64, 64, 64), color);

}

test "Quartz rim amount saturates at peak morph" {

    try std.testing.expectEqual(@as(u8, 0), rim_amount(0));
    try std.testing.expect(rim_amount(coordinate_one * 2) < rim_amount(coordinate_one * 8));
    try std.testing.expectEqual(@as(u8, 255), rim_amount(max_refraction * coordinate_one));
    try std.testing.expect(square_byte(200) > square_byte(100));

}

test "Quartz displacement treats surface bounds as clear space" {

    var pixels = [_]Color{draw.transparent} ** 4;
    var effect = [_]u8{ 32, 4, 64, 8, 96, 12, 127, 16 };
    var surface = Surface.from_pixels_format(&pixels, 2, 2, .alpha);

    surface.effect = &effect;
    surface.effect_stride = 4;

    try std.testing.expectEqual(@as(i32, 32), optical_displacement(&surface, 0, 0).x);
    try std.testing.expectEqual(@as(i32, 4), optical_displacement(&surface, 0, 0).y);
    try std.testing.expectEqual(@as(i32, 0), optical_displacement(&surface, -1, 0).x);
    try std.testing.expectEqual(@as(i32, 0), optical_displacement(&surface, 2, 1).y);

}

test "Quartz damage halo covers morph chroma and frost" {

    try std.testing.expect(damage_halo >= max_refraction + blur_radius);

}

test "Quartz wavelength dispersion bends blue farther than red" {

    var scene = [_]Color{

        draw.rgb(0, 0, 0),
        draw.rgb(10, 0, 20),
        draw.rgb(20, 0, 40),
        draw.rgb(30, 0, 60),
        draw.rgb(40, 0, 80),

    };
    const renderer = Renderer{ .width = 5, .height = 1, .scene = &scene };
    const ray = SampleRay{ .x = 2 * coordinate_one, .y = 0, .rim = 255, .nx = 256 };
    const dispersed = renderer.trace_glass(ray, .{ .x = 0, .y = 0, .w = 5, .h = 1 });

    try std.testing.expectEqual(@as(u8, 0), draw.red(dispersed));
    try std.testing.expectEqual(@as(u8, 80), draw.blue(dispersed));

}

test "Quartz frost reciprocal matches rounded division" {

    var sum: u32 = 0;

    while (sum <= frost_blur_count * 255) : (sum += 1) {

        try std.testing.expectEqual(@as(u8, @intCast((sum + frost_blur_count / 2) / frost_blur_count)), average_frost_channel(sum));

    }

}

test "Quartz header mask rounds only the top corners" {

    const rect = Rect{ .x = 10, .y = 20, .w = 80, .h = 28 };
    const radius: i32 = 8;
    const masks = draw.round.masks_for(radius);

    try std.testing.expect(header_coverage(rect, rect.x, rect.y, radius, masks) < 255);
    try std.testing.expectEqual(@as(u8, 255), header_coverage(rect, rect.x + @divTrunc(rect.w, 2), rect.y, radius, masks));
    try std.testing.expectEqual(@as(u8, 255), header_coverage(rect, rect.x, rect.y + rect.h - 1, radius, masks));

}

test "Quartz header lens bends every edge inward" {

    const rect = Rect{ .x = 10, .y = 20, .w = 100, .h = 28 };
    const left = header_displacement(rect, rect.x, rect.y + 14);
    const right = header_displacement(rect, rect.x + rect.w - 1, rect.y + 14);
    const center = header_displacement(rect, rect.x + 50, rect.y + 14);

    try std.testing.expect(left.x > 0);
    try std.testing.expect(right.x < 0);
    try std.testing.expectEqual(@as(i32, 0), center.x);
    try std.testing.expectEqual(@as(i32, 0), center.y);

}

test "Quartz regional cache preserves unrelated glass" {

    var renderer = Renderer{};
    const left = Rect{ .x = 10, .y = 10, .w = 40, .h = 30 };
    const right = Rect{ .x = 100, .y = 10, .w = 40, .h = 30 };

    renderer.store_output_cache(1, left, left);
    renderer.store_output_cache(2, right, right);
    renderer.invalidate_region(left);

    try std.testing.expect(!renderer.output_reusable(1, left, left));
    try std.testing.expect(renderer.output_reusable(2, right, right));

}

test "Quartz resolved output cache restores glass without recompositing" {

    var back_pixels = [_]Color{draw.rgb(10, 20, 30)};
    var foreground_pixels = [_]Color{draw.rgba(40, 80, 120, 128)};
    var scene_pixels = [_]Color{draw.rgb(100, 120, 140)};
    var frost_pixels = [_]Color{draw.rgb(100, 120, 140)};
    var output_pixels = [_]Color{draw.transparent};

    const back = Surface.from_pixels(&back_pixels, 1, 1);
    const foreground = Surface.from_pixels_format(&foreground_pixels, 1, 1, .alpha);
    var renderer = Renderer{

        .width = 1,
        .height = 1,

        .scene = &scene_pixels,
        .lens = &output_pixels,
        .temp = &frost_pixels,

    };

    renderer.resolve_compact(&back, &foreground, foreground.bounds(), foreground.bounds(), foreground.bounds(), foreground.bounds());

    const resolved = output_pixels[0];

    back_pixels[0] = draw.rgb(1, 2, 3);
    renderer.blit_cached(&back, back.bounds());

    try std.testing.expectEqual(draw.composite_premultiplied(frost_pixels[0], foreground_pixels[0]), resolved);
    try std.testing.expectEqual(resolved, back_pixels[0]);

}
