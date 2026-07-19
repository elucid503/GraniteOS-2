// Analytic-coverage rasterizer: adaptive curve flatten, per-cell area/cover sweep, exact subpixel alpha via nonzero winding.

const std = @import("std");

const draw = @import("draw.zig");
const path_mod = @import("path.zig");

const Path = path_mod.Path;
const Point = path_mod.Point;
const Rect = draw.Rect;
const Surface = draw.Surface;

// Width covers a full HD scanline; edge capacity is sized for icon/chrome paths (not freehand).
pub const max_width = 2048;
pub const max_edges = 4096;

const Edge = struct {

    // Endpoints in pixels, always y0 < y1; `winding` restores the original direction.
    x0: f32,
    y0: f32,

    x1: f32,
    y1: f32,

    winding: f32,

};

pub const Raster = struct {

    edges: [max_edges]Edge = undefined,
    edge_count: usize = 0,
    overflowed: bool = false,

    order: [max_edges]u16 = undefined,
    active: [max_edges]u16 = undefined,

    area: [max_width]f32 = [_]f32{0} ** max_width,
    cover: [max_width]f32 = [_]f32{0} ** max_width,
    alphas: [max_width]u8 = undefined,

    /// Fill path with nonzero winding into writer row callbacks; overflowed paths draw nothing.
    pub fn fill(self: *Raster, path: *const Path, clip: Rect, writer: anytype) void {

        if (path.overflowed or clip.is_empty()) return;

        self.gather(path, clip);

        if (self.overflowed or self.edge_count == 0) return;

        self.sweep(clip, writer);

    }

    // Flatten the path into clipped edges.

    fn gather(self: *Raster, path: *const Path, clip: Rect) void {

        self.edge_count = 0;
        self.overflowed = false;

        const x_min = path_mod.from_px(clip.x);
        const x_max = path_mod.from_px(clip.x + clip.w);


        var point: usize = 0;
        var start = Point{ .x = 0, .y = 0 };
        var current = Point{ .x = 0, .y = 0 };

        for (path.verbs[0..path.verb_count]) |verb| {

            switch (verb) {

                .move => {

                    // An unclosed previous contour still closes for filling.
                    self.add_edge(current, start, x_min, x_max);

                    start = path.points[point];
                    current = start;
                    point += 1;

                },

                .line => {

                    const p = path.points[point];

                    self.add_edge(current, p, x_min, x_max);

                    current = p;
                    point += 1;

                },

                .quad => {

                    const c = path.points[point];
                    const p = path.points[point + 1];

                    self.flatten_quad(current, c, p, x_min, x_max, 0);

                    current = p;
                    point += 2;

                },

                .cubic => {

                    const c1 = path.points[point];
                    const c2 = path.points[point + 1];
                    const p = path.points[point + 2];

                    self.flatten_cubic(current, c1, c2, p, x_min, x_max, 0);

                    current = p;
                    point += 3;

                },

                .close => {

                    self.add_edge(current, start, x_min, x_max);

                    current = start;

                },

            }

        }

        self.add_edge(current, start, x_min, x_max);

    }

    fn add_edge(self: *Raster, a: Point, b: Point, x_min: f32, x_max: f32) void {

        if (a.y == b.y) return;
        if (a.x == b.x and a.y == b.y) return;

        if (self.edge_count >= max_edges) {

            self.overflowed = true;

            return;

        }

        var edge = if (a.y < b.y) Edge{

            .x0 = a.x,
            .y0 = a.y,

            .x1 = b.x,
            .y1 = b.y,

            .winding = 1,

        } else Edge{

            .x0 = b.x,
            .y0 = b.y,

            .x1 = a.x,
            .y1 = a.y,

            .winding = -1,

        };

        // Clamp horizontal edges to clip so out-of-view geometry still contributes winding at the boundary.

        edge.x0 = std.math.clamp(edge.x0, x_min, x_max);
        edge.x1 = std.math.clamp(edge.x1, x_min, x_max);

        self.edges[self.edge_count] = edge;
        self.edge_count += 1;

    }

    const max_depth = 16;

    // Deviation limits in pixels, matching the 16/64 and 20/64 thresholds of the fixed-point raster.
    const quad_flatness: f32 = 0.25;
    const cubic_flatness: f32 = 0.3125;

    // Quarter-pixel flatness: keeps icon arcs and round-rect corners from faceting at small sizes.

    fn flatten_quad(self: *Raster, a: Point, b: Point, c: Point, x_min: f32, x_max: f32, depth: u8) void {

        const dev_x = @abs(2 * b.x - a.x - c.x);
        const dev_y = @abs(2 * b.y - a.y - c.y);

        // ~1/4 px flatness: keeps small mono stems and icon arcs from faceting without edge blow-up.
        if (depth >= max_depth or (dev_x <= quad_flatness and dev_y <= quad_flatness)) {

            self.add_edge(a, c, x_min, x_max);

            return;

        }

        const ab = midpoint(a, b);
        const bc = midpoint(b, c);
        const mid = midpoint(ab, bc);

        self.flatten_quad(a, ab, mid, x_min, x_max, depth + 1);
        self.flatten_quad(mid, bc, c, x_min, x_max, depth + 1);

    }

    fn flatten_cubic(self: *Raster, a: Point, b: Point, c: Point, d: Point, x_min: f32, x_max: f32, depth: u8) void {

        const dev1_x = @abs(3 * b.x - 2 * a.x - d.x);
        const dev1_y = @abs(3 * b.y - 2 * a.y - d.y);
        const dev2_x = @abs(3 * c.x - a.x - 2 * d.x);
        const dev2_y = @abs(3 * c.y - a.y - 2 * d.y);

        if (depth >= max_depth or (@max(dev1_x, dev2_x) <= cubic_flatness and @max(dev1_y, dev2_y) <= cubic_flatness)) {

            self.add_edge(a, d, x_min, x_max);

            return;

        }

        const ab = midpoint(a, b);
        const bc = midpoint(b, c);
        const cd = midpoint(c, d);
        const abc = midpoint(ab, bc);
        const bcd = midpoint(bc, cd);
        const mid = midpoint(abc, bcd);

        self.flatten_cubic(a, ab, abc, mid, x_min, x_max, depth + 1);
        self.flatten_cubic(mid, bcd, cd, d, x_min, x_max, depth + 1);

    }

    // Row sweep: active edges scatter into cells, then resolve to alphas.

    fn sweep(self: *Raster, clip: Rect, writer: anytype) void {

        var min_y: f32 = std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        for (self.edges[0..self.edge_count], 0..) |edge, index| {

            self.order[index] = @intCast(index);

            min_y = @min(min_y, edge.y0);
            max_y = @max(max_y, edge.y1);

        }

        const Sorter = struct {

            edges: []const Edge,

            pub fn lessThan(context: @This(), lhs: u16, rhs: u16) bool {

                return context.edges[lhs].y0 < context.edges[rhs].y0;

            }

        };

        std.sort.pdq(u16, self.order[0..self.edge_count], Sorter{ .edges = self.edges[0..self.edge_count] }, Sorter.lessThan);

        var y = @max(clip.y, @as(i32, @intFromFloat(@floor(min_y))));
        const y_end = @min(clip.y + clip.h, @as(i32, @intFromFloat(@ceil(max_y))));

        var next: usize = 0;
        var active_count: usize = 0;

        // Skip edges entirely above the first visible row.

        while (next < self.edge_count and self.edges[self.order[next]].y1 <= @as(f32, @floatFromInt(y))) : (next += 1) {}

        while (y < y_end) : (y += 1) {

            const row_top: f32 = @floatFromInt(y);
            const row_bottom = row_top + 1;

            while (next < self.edge_count and self.edges[self.order[next]].y0 < row_bottom) : (next += 1) {

                if (self.edges[self.order[next]].y1 <= row_top) continue;

                self.active[active_count] = self.order[next];
                active_count += 1;

            }

            if (active_count == 0) continue;

            var min_col: i32 = max_width;
            var max_col: i32 = -1;

            var slot: usize = 0;

            while (slot < active_count) {

                const edge = &self.edges[self.active[slot]];

                if (edge.y1 <= row_top) {

                    active_count -= 1;
                    self.active[slot] = self.active[active_count];

                    continue;

                }

                self.scatter(edge, row_top, row_bottom, clip, &min_col, &max_col);

                slot += 1;

            }

            if (max_col < min_col) continue;

            self.resolve(y, clip, min_col, max_col, writer);

        }

    }

    // Scatter one edge's intersection with the row band into the area/cover cells.

    fn scatter(self: *Raster, edge: *const Edge, row_top: f32, row_bottom: f32, clip: Rect, min_col: *i32, max_col: *i32) void {

        const ya = @max(edge.y0, row_top);
        const yb = @min(edge.y1, row_bottom);

        if (ya >= yb) return;

        const xa = x_at(edge, ya);
        const xb = x_at(edge, yb);

        var seg_x0 = xa;
        var seg_y0 = ya;

        const step: i32 = if (xb >= xa) 1 else -1;

        var col: i32 = @intFromFloat(@floor(xa));
        const last_col: i32 = @intFromFloat(@floor(xb));

        while (true) {

            const boundary: f32 = @floatFromInt(if (step > 0) col + 1 else col);

            var seg_x1 = xb;
            var seg_y1 = yb;

            if (col != last_col) {

                seg_x1 = boundary;
                seg_y1 = y_between(xa, ya, xb, yb, boundary);

            }

            self.deposit(col, seg_x0, seg_y0, seg_x1, seg_y1, edge.winding, clip, min_col, max_col);

            if (col == last_col) break;

            seg_x0 = seg_x1;
            seg_y0 = seg_y1;
            col += step;

        }

    }

    fn deposit(self: *Raster, col_in: i32, x0: f32, y0: f32, x1: f32, y1: f32, winding: f32, clip: Rect, min_col: *i32, max_col: *i32) void {

        const dy = y1 - y0;

        if (dy == 0) return;

        // Clip-relative cells so boundary-pinned edges deposit at the cell border, not inside it.

        const col = std.math.clamp(col_in - clip.x, 0, @as(i32, @intCast(@min(max_width, @as(usize, @intCast(clip.w))))) - 1);

        const cell_left: f32 = @floatFromInt(clip.x + col);
        const fx0 = std.math.clamp(x0 - cell_left, 0, 1);
        const fx1 = std.math.clamp(x1 - cell_left, 0, 1);

        const index: usize = @intCast(col);

        // The cell keeps the area left of the span; cells further right take the full `dy` via the accumulator.

        self.cover[index] += winding * dy;
        self.area[index] += winding * dy * (1 - (fx0 + fx1) * 0.5);

        min_col.* = @min(min_col.*, col);
        max_col.* = @max(max_col.*, col);

    }

    fn resolve(self: *Raster, y: i32, clip: Rect, min_col: i32, max_col: i32, writer: anytype) void {

        var acc: f32 = 0;
        var col = min_col;

        while (col <= max_col) : (col += 1) {

            const index: usize = @intCast(col);
            const total = acc + self.area[index];

            acc += self.cover[index];

            self.area[index] = 0;
            self.cover[index] = 0;

            self.alphas[index] = to_alpha(total);

        }

        // Tail past the last touched cell inherits the running accumulator (interior extends beyond clip).

        var run_end = max_col;

        // A closed contour cancels to ~0 rather than exactly 0 in float, so ignore accumulator dust
        // instead of smearing a faint run to the clip edge.

        if (@abs(acc) > coverage_epsilon) {

            const tail_alpha = to_alpha(acc);

            if (tail_alpha != 0) {

                const clip_last: i32 = @min(@as(i32, @intCast(max_width)), clip.w) - 1;

                var col_tail = max_col + 1;

                while (col_tail <= clip_last) : (col_tail += 1) {

                    self.alphas[@intCast(col_tail)] = tail_alpha;

                }

                run_end = clip_last;

            }

        }

        writer.row(y, clip.x + min_col, self.alphas[@intCast(min_col) .. @intCast(run_end + 1)]);

    }

};

// Linear analytic alpha here; display gamma belongs in SurfaceWriter compositing.

// Half an alpha step: below this the tail accumulator is rounding residue, not real coverage.
const coverage_epsilon: f32 = 0.5 / 255.0;

fn to_alpha(coverage: f32) u8 {

    return @intFromFloat(@min(255, @abs(coverage) * 255 + 0.5));

}

fn midpoint(a: Point, b: Point) Point {

    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };

}

fn x_at(edge: *const Edge, y: f32) f32 {

    const rise = edge.y1 - edge.y0;

    if (rise == 0) return edge.x0;

    return edge.x0 + (edge.x1 - edge.x0) * (y - edge.y0) / rise;

}

fn y_between(x0: f32, y0: f32, x1: f32, y1: f32, x: f32) f32 {

    const run = x1 - x0;

    if (run == 0) return y1;

    const interpolated = y0 + (y1 - y0) * (x - x0) / run;

    return std.math.clamp(interpolated, @min(y0, y1), @max(y0, y1));

}

// Single shared raster: one render thread per process, no locking.

pub var shared: Raster = .{};

const SurfaceWriter = struct {

    surface: *const Surface,
    color: draw.Color,

    pub fn row(self: @This(), y: i32, x: i32, coverage: []const u8) void {

        self.surface.blend_row(x, y, coverage, self.color);

    }

};

/// Fill `path` onto `surface` in `color`, clipped to the surface's clip rect.
pub fn fill(surface: *const Surface, path: *const Path, color: draw.Color) void {

    const clip = surface.clip.intersect(surface.bounds());

    shared.fill(path, clip, SurfaceWriter{ .surface = surface, .color = color });

}

const CoverageWriter = struct {

    buffer: []u8,

    w: u32,
    h: u32,

    origin_x: i32,
    origin_y: i32,

    pub fn row(self: @This(), y: i32, x: i32, coverage: []const u8) void {

        const local_y = y - self.origin_y;

        if (local_y < 0 or local_y >= self.h) return;

        var local_x = x - self.origin_x;
        var first: usize = 0;

        if (local_x < 0) {

            first = @intCast(-local_x);

            if (first >= coverage.len) return;

            local_x = 0;

        }

        const room: usize = @intCast(@as(i32, @intCast(self.w)) - local_x);
        const count = @min(coverage.len - first, room);

        if (count == 0 or room == 0) return;

        const start = @as(usize, @intCast(local_y)) * self.w + @as(usize, @intCast(local_x));

        // Saturating max: contours rasterized in separate passes still merge cleanly.

        var index: usize = 0;

        while (index < count) : (index += 1) {

            const merged = @max(self.buffer[start + index], coverage[first + index]);

            self.buffer[start + index] = merged;

        }

    }

};

/// Rasterize path into w×h 8-bit coverage at (origin_x, origin_y) for glyph/icon/mask caches.
pub fn fill_coverage(path: *const Path, buffer: []u8, w: u32, h: u32, origin_x: i32, origin_y: i32) void {

    const clip = Rect{ .x = origin_x, .y = origin_y, .w = @intCast(w), .h = @intCast(h) };

    shared.fill(path, clip, CoverageWriter{

        .buffer = buffer,

        .w = w,
        .h = h,

        .origin_x = origin_x,
        .origin_y = origin_y,

    });

}

const testing = std.testing;

test "a pixel-aligned square fills solid with clean edges" {

    var pixels: [64]u32 = [_]u32{0} ** 64;
    const surface = Surface.from_pixels(&pixels, 8, 8);

    var path = Path{};

    path.add_rect(path_mod.from_px(2), path_mod.from_px(2), path_mod.from_px(4), path_mod.from_px(4));

    fill(&surface, &path, 0xffffff);

    try testing.expectEqual(@as(u32, 0xffffff), pixels[3 * 8 + 3]);
    try testing.expectEqual(@as(u32, 0xffffff), pixels[2 * 8 + 2]);
    try testing.expectEqual(@as(u32, 0xffffff), pixels[5 * 8 + 5]);
    try testing.expectEqual(@as(u32, 0), pixels[1 * 8 + 1]);
    try testing.expectEqual(@as(u32, 0), pixels[6 * 8 + 6]);
    try testing.expectEqual(@as(u32, 0), pixels[3 * 8 + 1]);

}

test "a half-pixel offset edge blends at half intensity" {

    var pixels: [64]u32 = [_]u32{0} ** 64;
    const surface = Surface.from_pixels(&pixels, 8, 8);

    var path = Path{};

    // Left edge at x = 2.5px.

    path.add_rect(path_mod.from_px(2) + 0.5, path_mod.from_px(0), path_mod.from_px(4), path_mod.from_px(8));

    fill(&surface, &path, 0xffffff);

    const edge = draw.blue(pixels[4 * 8 + 2]);

    try testing.expect(edge > 100 and edge < 155);
    try testing.expectEqual(@as(u32, 0xffffff), pixels[4 * 8 + 3]);

}

test "nonzero winding fills a ring with a hole" {

    var pixels: [32 * 32]u32 = [_]u32{0} ** (32 * 32);
    const surface = Surface.from_pixels(&pixels, 32, 32);

    var path = Path{};

    path.add_ring(path_mod.from_px(16), path_mod.from_px(16), path_mod.from_px(14), path_mod.from_px(7));

    fill(&surface, &path, 0xffffff);

    // Solid inside the band, clear in the hole and outside.

    try testing.expectEqual(@as(u32, 0xffffff), pixels[16 * 32 + 5]);
    try testing.expectEqual(@as(u32, 0), pixels[16 * 32 + 16]);
    try testing.expectEqual(@as(u32, 0), pixels[1 * 32 + 1]);

}

test "clipping pins out-of-view geometry instead of dropping it" {

    var pixels: [16]u32 = [_]u32{0} ** 16;
    const surface = Surface.from_pixels(&pixels, 4, 4);

    var path = Path{};

    // A huge rect containing the whole surface.

    path.add_rect(path_mod.from_px(-100), path_mod.from_px(-100), path_mod.from_px(400), path_mod.from_px(400));

    fill(&surface, &path, 0xabcdef);

    for (pixels) |pixel| {

        try testing.expectEqual(@as(u32, 0xabcdef), pixel);

    }

}

test "subpixel edge positions finer than 1/64 px resolve distinctly" {

    // The old 26.6 tape quantised to 1/64 px (0.015625), so these two offsets were identical.

    var near: [64]u32 = [_]u32{0} ** 64;
    var far: [64]u32 = [_]u32{0} ** 64;

    for ([_]struct { pixels: *[64]u32, offset: f32 }{
        .{ .pixels = &near, .offset = 0.002 },
        .{ .pixels = &far, .offset = 0.012 },
    }) |case| {

        const surface = Surface.from_pixels(case.pixels, 8, 8);

        var path = Path{};

        path.add_rect(2 + case.offset, 0, 4, 8);
        fill(&surface, &path, 0xffffff);

    }

    const near_edge = draw.blue(near[4 * 8 + 2]);
    const far_edge = draw.blue(far[4 * 8 + 2]);

    // Both are nearly-full left-edge cells, but the farther offset must cover strictly less.

    try testing.expect(near_edge > far_edge);

}

test "a closed contour leaves no coverage smear past its right edge" {

    var pixels: [16 * 16]u32 = [_]u32{0} ** (16 * 16);
    const surface = Surface.from_pixels(&pixels, 16, 16);

    var path = Path{};

    // Fractional bounds make the winding accumulator cancel inexactly in float.

    path.add_rect(2.37, 2.11, 5.53, 6.29);
    fill(&surface, &path, 0xffffff);

    // Everything right of the shape stays untouched.

    try testing.expectEqual(@as(u32, 0), pixels[5 * 16 + 12]);
    try testing.expectEqual(@as(u32, 0), pixels[5 * 16 + 15]);

}

test "coverage bitmaps capture antialiased circles" {

    var buffer: [16 * 16]u8 = [_]u8{0} ** (16 * 16);

    var path = Path{};

    path.add_circle(path_mod.from_px(8), path_mod.from_px(8), path_mod.from_px(6));

    fill_coverage(&path, &buffer, 16, 16, 0, 0);

    try testing.expectEqual(@as(u8, 255), buffer[8 * 16 + 8]);
    try testing.expectEqual(@as(u8, 0), buffer[0]);

    // The rim carries partial coverage somewhere.

    var partial = false;

    for (buffer) |value| {

        if (value > 20 and value < 235) partial = true;

    }

    try testing.expect(partial);

}
