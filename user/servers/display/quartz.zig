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
const max_refraction: i32 = 30;

// Extra stretch on encoded D so bezel morph reads clearly.
const morph_gain_num = lib.quartz.compositor_morph_gain_num;
const morph_gain_den = lib.quartz.compositor_morph_gain_den;

// Keep RGB separation continuous while letting it read along high-contrast rims.
const chroma_peak: i32 = coordinate_one * 8 / 2;
const chroma_gate: u8 = 56;
const chroma_strength: u8 = 200;
const chroma_radius: i32 = @divTrunc(chroma_peak + coordinate_one - 1, coordinate_one);
const frost_scale: i32 = 2;
const frost_blur_light: i32 = 3;
const frost_blur_regular: i32 = 5;
const frost_blur_prominent: i32 = 8;
const header_bezel: i32 = 12;
const header_refraction: i32 = coordinate_one * 8;
const header_shift_denominator = morph_gain_den * coordinate_one;
const header_shift_pixels: i32 = @divTrunc(header_refraction * morph_gain_num + header_shift_denominator - 1, header_shift_denominator);

// How hard the sharp rim wins back over frost (0..255).
const rim_clarity: u8 = 0;
const mask_floor: u8 = 8;
const color_mask: Color = 0x00ff_ffff;
const coverage_clear = make_material_coverage(lib.quartz.material_opacity(.clear));
const coverage_regular = make_material_coverage(lib.quartz.material_opacity(.regular));
const coverage_prominent = make_material_coverage(lib.quartz.material_opacity(.prominent));

pub fn damage_halo(level: u8) i32 {

    return damage_halo_from_radius(frost_radius(level));

}

pub fn header_damage_halo(level: u8) i32 {

    return header_halo_from_radius(frost_radius(level));

}

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

    inline fn average_frost(self: PixelSum, count: u32) Color {

        return switch (count) {

            7 => average_frost_color(self, 7),
            11 => average_frost_color(self, 11),
            17 => average_frost_color(self, 17),
            else => unreachable,

        };

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
// Above 1080p, preserve compositor budget for screen-sized client surfaces instead.
const output_cache_max_bytes = 8 * 1024 * 1024;

const OutputCache = struct {

    valid: bool = false,
    window: u32 = 0,
    content: Rect = Rect.empty,
    visible: Rect = Rect.empty,
    backdrop: Rect = Rect.empty,

};

// Separate regions keep every plane below the buddy allocator's contiguous-run ceiling.
const Buffer = struct {

    region: Handle = 0,
    base: usize = 0,

    fn allocate(bytes: usize) !Buffer {

        const region = try sys.create(.region, bytes, cap.memory);
        const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch |failure| {

            sys.close(region) catch {};

            return failure;

        };

        return .{

            .region = region,
            .base = base,

        };

    }

    fn release(self: *Buffer) void {

        if (self.base != 0) sys.unmap(cap.self_space, self.base) catch {};
        if (self.region != 0) sys.close(self.region) catch {};

        self.* = .{};

    }

};

// Multi-core glass pipeline: helpers drain independent row/column units while the compositor thread
// works the same queue. Optics stay identical; large Files-style windows scale across cores.

const max_helpers = 3;
const worker_stack_pages = 16;
const page_size = 4096;
const parallel_min_units = 32;

const JobKind = enum(u8) {

    none = 0,
    blur_h,
    blur_v,
    downsample,
    resolve,
    header,

};

const ParallelJob = struct {

    kind: JobKind = .none,
    next: u32 = 0,
    limit: u32 = 0,
    finished: u32 = 0,

    source: [*]const Color = undefined,
    dest: [*]Color = undefined,
    rect: Rect = Rect.empty,
    radius: i32 = 0,
    plane_width: usize = 0,
    scene_width: usize = 0,
    scene: [*]const Color = undefined,
    scene_rect: Rect = Rect.empty,

    renderer: ?*Renderer = null,
    back: ?*const Surface = null,
    foreground: ?*const Surface = null,
    content: Rect = Rect.empty,
    visible: Rect = Rect.empty,
    frost_bounds: Rect = Rect.empty,

    tint: Color = 0,
    opacity: u8 = 0,
    header_radius: i32 = 0,
    joined: bool = false,

};

const Helper = struct {

    wake: Handle = 0,
    thread: Handle = 0,

};

var parallel_job: ParallelJob = .{};
var helpers: [max_helpers]Helper = [_]Helper{.{}} ** max_helpers;
var helper_count: u32 = 0;
var helper_boot_id: u32 = 0;
var pool_started = false;

fn ensure_pool() void {

    if (pool_started) return;

    pool_started = true;

    const cores: u32 = @intCast(@max(@as(u64, 1), lib.start.word(lib.proto.init.core_count_word)));
    const want: u32 = @min(max_helpers, if (cores > 1) cores - 1 else 0);
    var index: u32 = 0;

    while (index < want) : (index += 1) {

        const wake = sys.create(.notification, 0, 0) catch break;
        const stack = sys.create(.region, worker_stack_pages * page_size, cap.memory) catch {

            sys.close(wake) catch {};
            break;

        };
        const base = sys.map(cap.self_space, stack, 0, sys.read | sys.write) catch {

            sys.close(stack) catch {};
            sys.close(wake) catch {};
            break;

        };
        const thread = sys.create_thread(@intFromPtr(&helper_entry), base + worker_stack_pages * page_size) catch {

            sys.unmap(cap.self_space, base) catch {};
            sys.close(stack) catch {};
            sys.close(wake) catch {};
            break;

        };

        sys.close(stack) catch {};
        helpers[helper_count] = .{ .wake = wake, .thread = thread };
        helper_count += 1;
        sys.start(thread) catch {};

    }

}

fn helper_entry() callconv(.c) noreturn {

    const id = @atomicRmw(u32, &helper_boot_id, .Add, 1, .acq_rel);
    const wake = if (id < max_helpers) helpers[id].wake else 0;

    while (true) {

        _ = sys.wait(wake) catch sys.yield();

        const kind: JobKind = @enumFromInt(@atomicLoad(u8, @as(*u8, @ptrCast(&parallel_job.kind)), .acquire));

        if (kind == .none) continue;

        drain_units(kind);
        _ = @atomicRmw(u32, &parallel_job.finished, .Add, 1, .release);

    }

}

fn drain_units(kind: JobKind) void {

    while (true) {

        const index = @atomicRmw(u32, &parallel_job.next, .Add, 1, .acq_rel);

        if (index >= @atomicLoad(u32, &parallel_job.limit, .acquire)) return;

        process_unit(kind, index);

    }

}

fn parallel_run(kind: JobKind, units: u32) void {

    if (units == 0) return;

    ensure_pool();

    if (helper_count == 0 or units < parallel_min_units) {

        var index: u32 = 0;

        while (index < units) : (index += 1) process_unit(kind, index);

        return;

    }

    @atomicStore(u32, &parallel_job.next, 0, .release);
    @atomicStore(u32, &parallel_job.limit, units, .release);
    @atomicStore(u32, &parallel_job.finished, 0, .release);
    @atomicStore(u8, @as(*u8, @ptrCast(&parallel_job.kind)), @intFromEnum(kind), .release);

    var helper: u32 = 0;

    while (helper < helper_count) : (helper += 1) {

        sys.notify(helpers[helper].wake, 1) catch {};

    }

    drain_units(kind);

    while (@atomicLoad(u32, &parallel_job.finished, .acquire) < helper_count) sys.yield();

    @atomicStore(u8, @as(*u8, @ptrCast(&parallel_job.kind)), @intFromEnum(JobKind.none), .release);

}

fn process_unit(kind: JobKind, index: u32) void {

    switch (kind) {

        .none => {},

        .blur_h => blur_frost_horizontal_row(
            parallel_job.source,
            parallel_job.dest,
            parallel_job.rect,
            parallel_job.radius,
            parallel_job.plane_width,
            parallel_job.rect.y + @as(i32, @intCast(index)),
        ),

        .blur_v => blur_frost_vertical_column(
            parallel_job.source,
            parallel_job.dest,
            parallel_job.rect,
            parallel_job.radius,
            parallel_job.plane_width,
            parallel_job.rect.x + @as(i32, @intCast(index)),
        ),

        .downsample => downsample_scene_row(
            parallel_job.scene,
            parallel_job.dest,
            parallel_job.scene_rect,
            parallel_job.rect,
            parallel_job.scene_width,
            parallel_job.plane_width,
            parallel_job.rect.y + @as(i32, @intCast(index)),
        ),

        .resolve => {

            const renderer = parallel_job.renderer orelse return;
            const back = parallel_job.back orelse return;
            const foreground = parallel_job.foreground orelse return;

            renderer.resolve_compact_row(
                back,
                foreground,
                parallel_job.content,
                parallel_job.visible,
                parallel_job.scene_rect,
                parallel_job.frost_bounds,
                parallel_job.visible.y + @as(i32, @intCast(index)),
            );

        },

        .header => {

            const renderer = parallel_job.renderer orelse return;
            const back = parallel_job.back orelse return;

            renderer.resolve_header_row(
                back,
                parallel_job.content,
                parallel_job.visible,
                parallel_job.scene_rect,
                parallel_job.frost_bounds,
                parallel_job.tint,
                parallel_job.opacity,
                parallel_job.header_radius,
                parallel_job.joined,
                parallel_job.visible.y + @as(i32, @intCast(index)),
            );

        },

    }

}

pub const Renderer = struct {

    scene_buffer: Buffer = .{},
    lens_buffer: Buffer = .{},
    frost_buffer: Buffer = .{},

    width: u32 = 0,
    height: u32 = 0,

    frost_radius: i32 = frost_blur_regular,
    coverage_table: *const [256]u8 = &coverage_regular,

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

        var scene_buffer = try Buffer.allocate(plane_bytes);
        errdefer scene_buffer.release();

        var frost_buffer = try Buffer.allocate(compact_bytes);
        errdefer frost_buffer.release();

        var lens_buffer = if (plane_bytes <= output_cache_max_bytes)
            Buffer.allocate(plane_bytes) catch Buffer{}
        else
            Buffer{};
        errdefer lens_buffer.release();

        const scene: [*]Color = @ptrFromInt(scene_buffer.base);
        const frost: [*]Color = @ptrFromInt(frost_buffer.base);
        self.* = .{

            .scene_buffer = scene_buffer,
            .lens_buffer = lens_buffer,
            .frost_buffer = frost_buffer,

            .width = width,
            .height = height,

            .scene = scene,
            .lens = if (lens_buffer.base != 0) @ptrFromInt(lens_buffer.base) else undefined,
            .temp = frost,
            .scratch = frost + frost_pixels,

        };

    }

    pub fn release(self: *Renderer) void {

        self.scene_buffer.release();
        self.lens_buffer.release();
        self.frost_buffer.release();

        self.* = .{};

    }

    pub fn ready(self: *const Renderer) bool {

        return self.scene_buffer.base != 0 and self.frost_buffer.base != 0;

    }

    pub fn invalidate(self: *Renderer) void {

        for (&self.output_cache) |*entry| entry.valid = false;

    }

    pub fn invalidate_region(self: *Renderer, rect: Rect) void {

        if (rect.is_empty()) return;

        for (&self.output_cache) |*entry| {

            if (entry.valid and !entry.backdrop.intersect(rect).is_empty()) entry.valid = false;

        }

    }

    pub fn set_density(self: *Renderer, level: u8) void {

        const radius = frost_radius(level);
        const coverage_table: *const [256]u8 = switch (level) {

            1 => &coverage_clear,
            3 => &coverage_prominent,
            else => &coverage_regular,

        };

        if (radius == self.frost_radius and coverage_table == self.coverage_table) return;

        self.frost_radius = radius;
        self.coverage_table = coverage_table;
        self.invalidate();

    }

    pub fn composite(self: *Renderer, back: *const Surface, foreground: *const Surface, content: Rect, clip: Rect, window: u32) bool {

        if (!self.ready() or foreground.format != .alpha) return false;
        if (self.width != back.width or self.height != back.height) return false;

        if (self.lens_buffer.base == 0) self.lens = back.pixels;

        const available = Rect{

            .x = content.x,
            .y = content.y,
            .w = @intCast(foreground.width),
            .h = @intCast(foreground.height),

        };

        const visible = available.intersect(content).intersect(clip).intersect(back.bounds());

        if (visible.is_empty()) return true;

        if (self.output_reusable(window, content, visible)) {

            self.blit_cached(back, visible);

            return true;

        }

        self.invalidate_output_overlap(visible);

        const scene_rect = visible.inset(-damage_halo_from_radius(self.frost_radius)).intersect(back.bounds());

        self.capture_scene(back, scene_rect);
        const frost_bounds = self.build_frost(scene_rect);

        self.resolve_compact(back, foreground, content, visible, scene_rect, frost_bounds);

        self.store_output_cache(window, content, visible, scene_rect);

        return true;

    }

    pub fn composite_header(self: *Renderer, back: *const Surface, content: Rect, clip: Rect, window: u32, tint: Color, opacity: u8, radius: i32, joined: bool) bool {

        if (!self.ready() or opacity == 0) return false;
        if (self.width != back.width or self.height != back.height) return false;

        if (self.lens_buffer.base == 0) self.lens = back.pixels;

        const visible = content.intersect(clip).intersect(back.bounds());

        if (visible.is_empty()) return true;

        const cache_key = window ^ 0x8000_0000;

        if (self.output_reusable(cache_key, content, visible)) {

            self.blit_cached(back, visible);

            return true;

        }

        self.invalidate_output_overlap(visible);

        const scene_rect = visible.inset(-header_halo_from_radius(self.frost_radius)).intersect(back.bounds());

        self.capture_scene(back, scene_rect);
        const frost_bounds = self.build_frost(scene_rect);

        self.resolve_header(back, content, visible, scene_rect, frost_bounds, tint, opacity, radius, joined);

        self.store_output_cache(cache_key, content, visible, scene_rect);

        return true;

    }

    fn output_reusable(self: *const Renderer, window: u32, content: Rect, visible: Rect) bool {

        if (self.lens_buffer.base == 0) return false;

        for (&self.output_cache) |*entry| {

            if (!entry.valid or entry.window != window) continue;
            if (!rect_equal(entry.content, content)) continue;
            if (rect_covers(entry.visible, visible)) return true;

        }

        return false;

    }

    fn invalidate_output_overlap(self: *Renderer, changed: Rect) void {

        for (&self.output_cache) |*entry| {

            // A lens depends on its sampled halo even when its output does not overlap the change.
            if (entry.valid and !entry.backdrop.intersect(changed).is_empty()) entry.valid = false;

        }

    }

    fn store_output_cache(self: *Renderer, window: u32, content: Rect, visible: Rect, backdrop: Rect) void {

        if (self.lens_buffer.base == 0) return;

        var available: ?*OutputCache = null;

        for (&self.output_cache) |*entry| {

            if (!entry.valid) {

                if (available == null) available = entry;

                continue;

            }

            if (entry.window == window) {

                available = entry;

                break;

            }

        }

        const target = available orelse &self.output_cache[@as(usize, window) % self.output_cache.len];

        target.* = .{

            .valid = true,
            .window = window,
            .content = content,
            .visible = visible,
            .backdrop = backdrop,

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
        const scale: usize = @intCast(frost_scale);
        const plane_width = (@as(usize, self.width) + scale - 1) / scale;

        parallel_job.scene = self.scene;
        parallel_job.dest = self.temp;
        parallel_job.scene_rect = scene_rect;
        parallel_job.rect = rect;
        parallel_job.scene_width = self.width;
        parallel_job.plane_width = plane_width;
        parallel_run(.downsample, @intCast(@max(0, rect.h)));

        parallel_job.source = self.temp;
        parallel_job.dest = self.scratch;
        parallel_job.rect = rect;
        parallel_job.radius = self.frost_radius;
        parallel_job.plane_width = plane_width;
        parallel_run(.blur_h, @intCast(@max(0, rect.h)));

        parallel_job.source = self.scratch;
        parallel_job.dest = self.temp;
        parallel_job.rect = rect;
        parallel_job.radius = self.frost_radius;
        parallel_job.plane_width = plane_width;
        parallel_run(.blur_v, @intCast(@max(0, rect.w)));

        return rect;

    }

    // One glass ray: refracted offset from D, optional RGB dispersion near the rim.
    inline fn trace_glass(self: *const Renderer, ray: SampleRay, scene_rect: Rect) Color {

        const center = self.sample_scene(ray.x, ray.y, scene_rect);

        const chroma_weight = chroma_amount(ray.rim);

        if (chroma_weight == 0) return center;

        const chroma_mag = @divTrunc(@as(i32, chroma_weight) * chroma_peak, 255);
        const chroma_x = @divTrunc(ray.nx * chroma_mag, 256);
        const chroma_y = @divTrunc(ray.ny * chroma_mag, 256);

        const red_s = self.sample_scene(ray.x - chroma_x, ray.y - chroma_y, scene_rect);
        const blue_s = self.sample_scene(ray.x + chroma_x, ray.y + chroma_y, scene_rect);

        // Bake dispersion into a single lens color — not a post on the live buffer.
        const dispersed = draw.rgb(draw.red(red_s), draw.green(center), draw.blue(blue_s));

        return draw.mix(center, dispersed, scale_byte(chroma_weight, chroma_strength));

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

    // Shared glass core: frost sample, rim clarity, and material composite. Both resolve passes route through this.
    inline fn resolve_glass(self: *const Renderer, x: i32, y: i32, displacement: Displacement, coverage: u8, material: Color, original: Color, scene_rect: Rect, frost_bounds: Rect) Color {

        const ray = self.ray_from_displacement(x, y, displacement);
        var optical = self.sample_frost(ray.x, ray.y, frost_bounds);

        if (ray.rim > chroma_gate) {

            const sharp = self.trace_glass(ray, scene_rect);
            const clarity = scale_byte(square_byte(ray.rim), rim_clarity);

            optical = draw.mix(optical, sharp, clarity);

        }

        const glass = draw.composite_premultiplied(optical, material);

        return draw.mix(original, glass, coverage);

    }

    /// Flat interior glass (no bezel displacement): frost + tint only.
    inline fn resolve_flat_glass(self: *const Renderer, x: i32, y: i32, coverage: u8, material: Color, original: Color, frost_bounds: Rect) Color {

        const optical = self.sample_frost(x * coordinate_one, y * coordinate_one, frost_bounds);
        const glass = draw.composite_premultiplied(optical, material);

        return draw.mix(original, glass, coverage);

    }

    fn resolve_compact(self: *Renderer, back: *const Surface, foreground: *const Surface, content: Rect, visible: Rect, scene_rect: Rect, frost_bounds: Rect) void {

        parallel_job.renderer = self;
        parallel_job.back = back;
        parallel_job.foreground = foreground;
        parallel_job.content = content;
        parallel_job.visible = visible;
        parallel_job.scene_rect = scene_rect;
        parallel_job.frost_bounds = frost_bounds;
        parallel_run(.resolve, @intCast(@max(0, visible.h)));

    }

    fn resolve_compact_row(
        self: *Renderer,
        back: *const Surface,
        foreground: *const Surface,
        content: Rect,
        visible: Rect,
        scene_rect: Rect,
        frost_bounds: Rect,
        y: i32,
    ) void {

        if (y < visible.y or y >= visible.y + visible.h) return;

        const source_y: u32 = @intCast(y - content.y);
        const row = source_y * foreground.stride;
        const destination_row = @as(usize, @intCast(y)) * back.stride;
        const cache_row = @as(usize, @intCast(y)) * @as(usize, self.width);
        var x = visible.x;

        while (x < visible.x + visible.w) : (x += 1) {

            const source_x: u32 = @intCast(x - content.x);
            const source = foreground.pixels[row + source_x];
            const opacity = draw.pixel_alpha(source);
            const destination_index = destination_row + @as(usize, @intCast(x));
            const cache_index = cache_row + @as(usize, @intCast(x));
            const original = back.pixels[destination_index];
            var resolved = original;

            if (opacity == 255) {

                resolved = source;

            } else if (opacity != 0 and !is_material(source)) {

                resolved = draw.composite_premultiplied(original, source);

            } else if (opacity != 0) {

                const coverage = self.coverage_table[opacity];
                const displacement = optical_displacement(foreground, @intCast(source_x), @intCast(source_y));

                // Window interiors (and other flat material) skip morph/chroma but still sample frost.
                if (displacement.x == 0 and displacement.y == 0) {

                    resolved = self.resolve_flat_glass(x, y, coverage, source, original, frost_bounds);

                } else {

                    resolved = self.resolve_glass(x, y, displacement, coverage, source, original, scene_rect, frost_bounds);

                }

            }

            self.lens[cache_index] = resolved;
            back.pixels[destination_index] = resolved;

        }

    }

    fn resolve_header(self: *Renderer, back: *const Surface, content: Rect, visible: Rect, scene_rect: Rect, frost_bounds: Rect, tint: Color, opacity: u8, radius: i32, joined: bool) void {

        parallel_job.renderer = self;
        parallel_job.back = back;
        parallel_job.content = content;
        parallel_job.visible = visible;
        parallel_job.scene_rect = scene_rect;
        parallel_job.frost_bounds = frost_bounds;
        parallel_job.tint = tint;
        parallel_job.opacity = opacity;
        parallel_job.header_radius = radius;
        parallel_job.joined = joined;
        parallel_run(.header, @intCast(@max(0, visible.h)));

    }

    fn resolve_header_row(
        self: *Renderer,
        back: *const Surface,
        content: Rect,
        visible: Rect,
        scene_rect: Rect,
        frost_bounds: Rect,
        tint: Color,
        opacity: u8,
        radius: i32,
        joined: bool,
        y: i32,
    ) void {

        if (y < visible.y or y >= visible.y + visible.h) return;

        const material = draw.with_alpha(tint, opacity);
        const r = draw.round.clamp_radius(content, radius);
        const masks = draw.round.masks_for(r);
        const bezel = header_bezel;
        const refraction = lib.quartz.safe_refraction(header_refraction, bezel);
        const profile = HeaderProfile.init(bezel, refraction);
        const displacement_y = header_vertical(content, y, &profile, joined);
        const destination_row = @as(usize, @intCast(y)) * back.stride;
        const cache_row = @as(usize, @intCast(y)) * @as(usize, self.width);
        var x = visible.x;

        while (x < visible.x + visible.w) : (x += 1) {

            const destination_index = destination_row + @as(usize, @intCast(x));
            const cache_index = cache_row + @as(usize, @intCast(x));
            const coverage = header_coverage(content, x, y, r, masks);
            const original = back.pixels[destination_index];

            if (coverage == 0) {

                self.lens[cache_index] = original;

                continue;

            }

            const displacement = attenuate_displacement(.{

                .x = header_horizontal(content, x, &profile),
                .y = displacement_y,

            }, coverage);
            const resolved = self.resolve_glass(x, y, displacement, coverage, material, original, scene_rect, frost_bounds);

            self.lens[cache_index] = resolved;
            back.pixels[destination_index] = resolved;

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
        const width = @as(usize, self.width);
        const x_index: usize = @intCast(x);
        const next_x_index: usize = @intCast(next_x);
        const top = @as(usize, @intCast(y)) * width;
        const bottom = @as(usize, @intCast(next_y)) * width;

        if (fraction_x == 0 and fraction_y == 0) return self.scene[top + x_index] & color_mask;

        return bilinear_color(
            self.scene[top + x_index],
            self.scene[top + next_x_index],
            self.scene[bottom + x_index],
            self.scene[bottom + next_x_index],
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
        const scale: usize = @intCast(frost_scale);
        const width = (@as(usize, self.width) + scale - 1) / scale;
        const x_index: usize = @intCast(x);
        const next_x_index: usize = @intCast(next_x);
        const top = @as(usize, @intCast(y)) * width;
        const bottom = @as(usize, @intCast(next_y)) * width;

        if (fraction_x == 0 and fraction_y == 0) return self.temp[top + x_index] & color_mask;

        return bilinear_color(
            self.temp[top + x_index],
            self.temp[top + next_x_index],
            self.temp[bottom + x_index],
            self.temp[bottom + next_x_index],
            fraction_x,
            fraction_y,
        );

    }

    inline fn pixel_index(self: *const Renderer, x: i32, y: i32) usize {

        return @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));

    }

};

fn downsample_scene_row(
    scene: [*]const Color,
    dest: [*]Color,
    scene_rect: Rect,
    rect: Rect,
    scene_width: usize,
    plane_width: usize,
    y: i32,
) void {

    if (y < rect.y or y >= rect.y + rect.h) return;

    const max_x = scene_rect.x + scene_rect.w - 1;
    const max_y = scene_rect.y + scene_rect.h - 1;
    const source_y = clamp_axis(y * frost_scale, scene_rect.y, max_y);
    const next_y = @min(source_y + 1, max_y);
    const source_top = @as(usize, @intCast(source_y)) * scene_width;
    const source_bottom = @as(usize, @intCast(next_y)) * scene_width;
    const destination_row = @as(usize, @intCast(y)) * plane_width;
    var x = rect.x;

    while (x < rect.x + rect.w) : (x += 1) {

        const source_x = clamp_axis(x * frost_scale, scene_rect.x, max_x);
        const next_x = @min(source_x + 1, max_x);
        const source_index: usize = @intCast(source_x);
        const next_index: usize = @intCast(next_x);

        dest[destination_row + @as(usize, @intCast(x))] = average_four(
            scene[source_top + source_index],
            scene[source_top + next_index],
            scene[source_bottom + source_index],
            scene[source_bottom + next_index],
        );

    }

}

fn blur_frost_horizontal_row(
    source: [*]const Color,
    destination: [*]Color,
    rect: Rect,
    radius: i32,
    width: usize,
    y: i32,
) void {

    if (y < rect.y or y > rect.y + rect.h - 1) return;

    const min_x = rect.x;
    const max_x = rect.x + rect.w - 1;
    const count: u32 = @intCast(radius * 2 + 1);
    var sum = PixelSum{};
    var offset = -radius;
    const row = @as(usize, @intCast(y)) * width;

    while (offset <= radius) : (offset += 1) {

        sum.add(source[row + @as(usize, @intCast(clamp_axis(min_x + offset, min_x, max_x)))]);

    }

    var x = min_x;

    while (x <= max_x) : (x += 1) {

        destination[row + @as(usize, @intCast(x))] = sum.average_frost(count);

        const leaving_x = clamp_axis(x - radius, min_x, max_x);
        const entering_x = clamp_axis(x + radius + 1, min_x, max_x);

        sum.remove(source[row + @as(usize, @intCast(leaving_x))]);
        sum.add(source[row + @as(usize, @intCast(entering_x))]);

    }

}

fn blur_frost_vertical_column(
    source: [*]const Color,
    destination: [*]Color,
    rect: Rect,
    radius: i32,
    width: usize,
    x: i32,
) void {

    if (x < rect.x or x > rect.x + rect.w - 1) return;

    const min_y = rect.y;
    const max_y = rect.y + rect.h - 1;
    const count: u32 = @intCast(radius * 2 + 1);
    var sum = PixelSum{};
    var offset = -radius;
    const column: usize = @intCast(x);

    while (offset <= radius) : (offset += 1) {

        const sample_y = clamp_axis(min_y + offset, min_y, max_y);

        sum.add(source[@as(usize, @intCast(sample_y)) * width + column]);

    }

    var y = min_y;

    while (y <= max_y) : (y += 1) {

        destination[@as(usize, @intCast(y)) * width + column] = sum.average_frost(count);

        const leaving_y = clamp_axis(y - radius, min_y, max_y);
        const entering_y = clamp_axis(y + radius + 1, min_y, max_y);

        sum.remove(source[@as(usize, @intCast(leaving_y)) * width + column]);
        sum.add(source[@as(usize, @intCast(entering_y)) * width + column]);

    }

}

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

const HeaderProfile = struct {

    bezel: i32,
    components: [header_bezel]i32 = [_]i32{0} ** header_bezel,

    fn init(bezel: i32, refraction: i32) HeaderProfile {

        var result = HeaderProfile{

            .bezel = bezel,

        };
        var distance: i32 = 0;

        while (distance < bezel) : (distance += 1) {

            result.components[@intCast(distance)] = header_profile(distance, bezel, refraction);

        }

        return result;

    }

    inline fn component(self: *const HeaderProfile, distance: i32) i32 {

        if (distance < 0 or distance >= self.bezel) return 0;

        const index: usize = @intCast(distance);

        // self.bezel is a runtime load, so the guard above isn't comptime-foldable; bound against the array length so a comptime-constant distance can't trip a comptime index check.
        if (index >= self.components.len) return 0;

        return self.components[index];

    }

};

inline fn attenuate_displacement(displacement: Displacement, coverage: u8) Displacement {

    if (coverage == 255) return displacement;

    return .{

        .x = @divTrunc(displacement.x * @as(i32, coverage), 255),
        .y = @divTrunc(displacement.y * @as(i32, coverage), 255),

    };

}

inline fn header_horizontal(rect: Rect, x: i32, profile: *const HeaderProfile) i32 {

    const local_x = x - rect.x;
    const right = rect.w - 1 - local_x;
    var displacement: i32 = 0;

    if (local_x < profile.bezel) displacement -= profile.component(local_x);
    if (right < profile.bezel) displacement += profile.component(right);

    return displacement;

}

inline fn header_vertical(rect: Rect, y: i32, profile: *const HeaderProfile, joined: bool) i32 {

    const local_y = y - rect.y;
    const bottom = rect.h - 1 - local_y;
    var displacement: i32 = 0;

    if (local_y < profile.bezel) displacement -= profile.component(local_y);
    if (!joined and bottom < profile.bezel) displacement += profile.component(bottom);

    return displacement;

}

inline fn header_displacement(rect: Rect, x: i32, y: i32, profile: *const HeaderProfile, joined: bool) Displacement {

    return .{

        .x = header_horizontal(rect, x, profile),
        .y = header_vertical(rect, y, profile, joined),

    };

}

inline fn header_profile(distance: i32, bezel: i32, refraction: i32) i32 {

    const remaining = bezel - @max(0, distance);
    const profile = lib.quartz.lens_profile(remaining, bezel);

    return @divTrunc(@as(i32, profile) * refraction + 127, 255);

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

    return draw.pixel_alpha(color) > mask_floor;

}

fn make_material_coverage(comptime material_alpha: u8) [256]u8 {

    var table: [256]u8 = undefined;
    const floor: u32 = mask_floor;
    const expected: u32 = material_alpha;

    for (&table, 0..) |*coverage, opacity| {

        const value: u32 = @intCast(opacity);

        if (value <= floor) {

            coverage.* = 0;

        } else if (value >= expected) {

            coverage.* = 255;

        } else {

            coverage.* = @intCast((value * 255 + expected / 2) / expected);

        }

    }

    return table;

}

inline fn normal_denominator(x: i32, y: i32) i32 {

    const ax = abs_axis(x);
    const ay = abs_axis(y);

    return @max(ax, ay) + (@min(ax, ay) >> 1);

}

// Saturate the rim response before amplified client displacement can wrap.
inline fn rim_amount(slope: i32) u8 {

    return @intCast(clamp_axis(@divTrunc(slope * 255, max_refraction * coordinate_one), 0, 255));

}

inline fn scale_byte(value: u8, amount: u8) u8 {

    return @intCast((@as(u32, value) * amount + 127) / 255);

}

inline fn average_frost_color(sum: PixelSum, comptime count: u32) Color {

    return draw.rgb(
        average_frost_channel_exact(sum.red, count),
        average_frost_channel_exact(sum.green, count),
        average_frost_channel_exact(sum.blue, count),
    );

}

inline fn average_frost_channel_exact(sum: u32, comptime count: u32) u8 {

    return @intCast((sum + count / 2) / count);

}

inline fn frost_radius(level: u8) i32 {

    return switch (level) {

        1 => frost_blur_light,
        3 => frost_blur_prominent,
        else => frost_blur_regular,

    };

}

inline fn blur_radius(level: u8) i32 {

    return frost_scale * frost_radius(level);

}

inline fn damage_halo_from_radius(radius: i32) i32 {

    return max_refraction + chroma_radius + frost_scale * radius + 1;

}

inline fn header_halo_from_radius(radius: i32) i32 {

    return header_shift_pixels + chroma_radius + frost_scale * radius + 1;

}

inline fn square_byte(value: u8) u8 {

    return scale_byte(value, value);

}

inline fn chroma_amount(rim: u8) u8 {

    if (rim <= chroma_gate) return 0;

    const range: u32 = 255 - chroma_gate;
    const value: u32 = rim - chroma_gate;
    const normalized: u8 = @intCast((value * 255 + range / 2) / range);

    return square_byte(normalized);

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

test "Quartz coverage follows material density and excludes shadows" {

    try std.testing.expectEqual(@as(u8, 0), coverage_regular[mask_floor]);
    try std.testing.expectEqual(@as(u8, 255), coverage_regular[lib.quartz.material_opacity(.regular)]);
    try std.testing.expect(coverage_clear[40] > coverage_regular[40]);
    try std.testing.expect(coverage_regular[40] > coverage_prominent[40]);
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

    try std.testing.expect(damage_halo(3) >= max_refraction + blur_radius(3));

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

    try std.testing.expect(draw.red(dispersed) > 0);
    try std.testing.expect(draw.red(dispersed) < 20);
    try std.testing.expect(draw.blue(dispersed) > 40);
    try std.testing.expect(draw.blue(dispersed) < 80);

}

test "Quartz frost average matches rounded division" {

    inline for ([_]u32{ 7, 11, 17 }) |count| {

        var sum: u32 = 0;

        while (sum <= count * 255) : (sum += 1) {

            try std.testing.expectEqual(@as(u8, @intCast((sum + count / 2) / count)), average_frost_channel_exact(sum, count));

        }

    }

}

test "Quartz density progressively increases compact blur" {

    var renderer = Renderer{};

    try std.testing.expect(frost_blur_regular - frost_blur_light < frost_blur_prominent - frost_blur_regular);

    renderer.set_density(1);
    try std.testing.expectEqual(frost_blur_light, renderer.frost_radius);

    renderer.set_density(2);
    try std.testing.expectEqual(frost_blur_regular, renderer.frost_radius);

    renderer.set_density(3);
    try std.testing.expectEqual(frost_blur_prominent, renderer.frost_radius);

}

test "Quartz header mask rounds only the top corners" {

    const rect = Rect{ .x = 10, .y = 20, .w = 80, .h = 28 };
    const radius: i32 = 8;
    const masks = draw.round.masks_for(radius);

    try std.testing.expect(header_coverage(rect, rect.x, rect.y, radius, masks) < 255);
    try std.testing.expectEqual(@as(u8, 255), header_coverage(rect, rect.x + @divTrunc(rect.w, 2), rect.y, radius, masks));
    try std.testing.expectEqual(@as(u8, 255), header_coverage(rect, rect.x, rect.y + rect.h - 1, radius, masks));

}

test "Quartz header coverage attenuates corner displacement" {

    const displacement = Displacement{ .x = 64, .y = -64 };
    const partial = attenuate_displacement(displacement, 96);

    try std.testing.expect(partial.x > 0 and partial.x < displacement.x);
    try std.testing.expect(partial.y < 0 and partial.y > displacement.y);

}

test "Quartz header lens bends every edge outward" {

    const rect = Rect{ .x = 10, .y = 20, .w = 100, .h = 28 };
    const bezel = header_bezel;
    const refraction = lib.quartz.safe_refraction(header_refraction, bezel);
    const profile = HeaderProfile.init(bezel, refraction);
    const left = header_displacement(rect, rect.x, rect.y + 14, &profile, false);
    const right = header_displacement(rect, rect.x + rect.w - 1, rect.y + 14, &profile, false);
    const center = header_displacement(rect, rect.x + 50, rect.y + 14, &profile, false);

    try std.testing.expect(left.x < 0);
    try std.testing.expect(right.x > 0);
    try std.testing.expectEqual(@as(i32, 0), center.x);
    try std.testing.expectEqual(@as(i32, 0), center.y);

}

test "Quartz joined header leaves its content seam optically flat" {

    const rect = Rect{ .x = 10, .y = 20, .w = 100, .h = 28 };
    const x = rect.x + @divTrunc(rect.w, 2);
    const y = rect.y + rect.h - 1;
    const bezel = header_bezel;
    const refraction = lib.quartz.safe_refraction(header_refraction, bezel);
    const profile = HeaderProfile.init(bezel, refraction);
    const separate = header_displacement(rect, x, y, &profile, false);
    const joined = header_displacement(rect, x, y, &profile, true);

    try std.testing.expect(separate.y > 0);
    try std.testing.expectEqual(@as(i32, 0), joined.y);

}

test "Quartz regional cache preserves unrelated glass" {

    var renderer = Renderer{

        .lens_buffer = .{

            .base = 1,

        },

    };
    const left = Rect{ .x = 10, .y = 10, .w = 40, .h = 30 };
    const right = Rect{ .x = 100, .y = 10, .w = 40, .h = 30 };
    const left_backdrop = left.inset(-damage_halo(3));
    const right_backdrop = right.inset(-damage_halo(3));

    renderer.store_output_cache(1, left, left, left_backdrop);
    renderer.store_output_cache(2, right, right, right_backdrop);
    renderer.invalidate_region(.{ .x = left_backdrop.x, .y = left_backdrop.y, .w = 1, .h = 1 });

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

    const glass = draw.composite_premultiplied(frost_pixels[0], foreground_pixels[0]);
    const expected = draw.mix(draw.rgb(10, 20, 30), glass, coverage_regular[draw.pixel_alpha(foreground_pixels[0])]);

    try std.testing.expectEqual(expected, resolved);
    try std.testing.expectEqual(resolved, back_pixels[0]);

}

test "Quartz material coverage attenuates antialiased refraction" {

    const original = draw.rgb(10, 20, 30);
    const material = draw.rgba(80, 100, 120, 40);
    const frost = draw.rgb(100, 120, 140);
    var back_pixels = [_]Color{original};
    var foreground_pixels = [_]Color{material};
    var scene_pixels = [_]Color{frost};
    var frost_pixels = [_]Color{frost};
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

    renderer.set_density(3);
    renderer.resolve_compact(&back, &foreground, foreground.bounds(), foreground.bounds(), foreground.bounds(), foreground.bounds());

    const glass = draw.composite_premultiplied(frost, material);

    try std.testing.expect(coverage_prominent[40] < 64);
    try std.testing.expectEqual(draw.mix(original, glass, coverage_prominent[40]), back_pixels[0]);
    try std.testing.expect(back_pixels[0] != glass);

}
