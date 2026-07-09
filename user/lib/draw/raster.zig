// Analytic-coverage scanline rasterizer (the FreeType "smooth" cell algorithm, integer-only): curves are
// flattened adaptively to 26.6 segments, each segment scatters exact signed area/cover into per-row cells, and
// a left-to-right sweep turns the cells into an 8-bit alpha run per scanline. Coverage is exact to the
// subpixel - no sample grids, no banding - and nonzero winding falls out of the signed accumulation.

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

// One pixel of full coverage: 64 subpixels of height times 128 (double the 64-wide area term).
const full_coverage: i64 = 64 * 128;



const Edge = struct {

    // Endpoints in 26.6, always y0 < y1; `winding` restores the original direction.
    x0: i32,
    y0: i32,

    x1: i32,
    y1: i32,

    winding: i32,

};

pub const Raster = struct {

    edges: [max_edges]Edge = undefined,
    edge_count: usize = 0,
    overflowed: bool = false,

    order: [max_edges]u16 = undefined,
    active: [max_edges]u16 = undefined,

    area: [max_width]i32 = [_]i32{0} ** max_width,
    cover: [max_width]i32 = [_]i32{0} ** max_width,
    alphas: [max_width]u8 = undefined,

    /// Fill `path` with nonzero winding, clipped to `clip` (pixels), delivering alpha runs to
    /// `writer.row(y, x, coverage)`. Overflowing or truncated paths draw nothing rather than draw wrong.
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

    fn add_edge(self: *Raster, a: Point, b: Point, x_min: i32, x_max: i32) void {

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

        // Horizontal clamp: an edge outside the clip still carries its winding into the visible span, so it
        // pins to the boundary instead of being dropped.

        edge.x0 = std.math.clamp(edge.x0, x_min, x_max);
        edge.x1 = std.math.clamp(edge.x1, x_min, x_max);

        self.edges[self.edge_count] = edge;
        self.edge_count += 1;

    }

    const max_depth = 16;

    // Quarter-pixel flatness: keeps icon arcs and round-rect corners from faceting at small sizes.

    fn flatten_quad(self: *Raster, a: Point, b: Point, c: Point, x_min: i32, x_max: i32, depth: u8) void {

        const dev_x = @abs(2 * b.x - a.x - c.x);
        const dev_y = @abs(2 * b.y - a.y - c.y);

        // ~3/8 px flatness: sharper than 1/2 px without exploding edge counts on icons.
        if (depth >= max_depth or (dev_x <= 24 and dev_y <= 24)) {

            self.add_edge(a, c, x_min, x_max);

            return;

        }

        const ab = midpoint(a, b);
        const bc = midpoint(b, c);
        const mid = midpoint(ab, bc);

        self.flatten_quad(a, ab, mid, x_min, x_max, depth + 1);
        self.flatten_quad(mid, bc, c, x_min, x_max, depth + 1);

    }

    fn flatten_cubic(self: *Raster, a: Point, b: Point, c: Point, d: Point, x_min: i32, x_max: i32, depth: u8) void {

        const dev1_x = @abs(3 * b.x - 2 * a.x - d.x);
        const dev1_y = @abs(3 * b.y - 2 * a.y - d.y);
        const dev2_x = @abs(3 * c.x - a.x - 2 * d.x);
        const dev2_y = @abs(3 * c.y - a.y - 2 * d.y);

        if (depth >= max_depth or (@max(dev1_x, dev2_x) <= 32 and @max(dev1_y, dev2_y) <= 32)) {

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

    // Row sweep: keep edges sorted by top, maintain the active set, scatter each active edge's slice of the
    // row into cells, then resolve cells to alphas.

    fn sweep(self: *Raster, clip: Rect, writer: anytype) void {

        var min_y: i32 = std.math.maxInt(i32);
        var max_y: i32 = std.math.minInt(i32);

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

        var y = @max(clip.y, @divFloor(min_y, 64));
        const y_end = @min(clip.y + clip.h, @divFloor(max_y + 63, 64));

        var next: usize = 0;
        var active_count: usize = 0;

        // Skip edges entirely above the first visible row.

        while (next < self.edge_count and self.edges[self.order[next]].y1 <= y * 64) : (next += 1) {}

        while (y < y_end) : (y += 1) {

            const row_top = y * 64;
            const row_bottom = row_top + 64;

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

    fn scatter(self: *Raster, edge: *const Edge, row_top: i32, row_bottom: i32, clip: Rect, min_col: *i32, max_col: *i32) void {

        const ya = @max(edge.y0, row_top);
        const yb = @min(edge.y1, row_bottom);

        if (ya >= yb) return;

        const xa = x_at(edge, ya);
        const xb = x_at(edge, yb);

        var seg_x0 = xa;
        var seg_y0 = ya;

        const step: i32 = if (xb >= xa) 1 else -1;

        var col = @divFloor(xa, 64);
        const last_col = @divFloor(xb, 64);

        while (true) {

            const boundary: i32 = if (step > 0) (col + 1) * 64 else col * 64;

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

    fn deposit(self: *Raster, col_in: i32, x0: i32, y0: i32, x1: i32, y1: i32, winding: i32, clip: Rect, min_col: *i32, max_col: *i32) void {

        const dy = y1 - y0;

        if (dy == 0) return;

        // Cell indices are clip-relative; a clamped column measures fractions from its own left edge so
        // boundary-pinned geometry lands at the cell border, not inside it.

        const col = std.math.clamp(col_in - clip.x, 0, @as(i32, @intCast(@min(max_width, @as(usize, @intCast(clip.w))))) - 1);

        const cell_left = (clip.x + col) * 64;
        const fx0 = std.math.clamp(x0 - cell_left, 0, 64);
        const fx1 = std.math.clamp(x1 - cell_left, 0, 64);

        const index: usize = @intCast(col);

        self.cover[index] += winding * dy;
        self.area[index] += winding * dy * (128 - fx0 - fx1);

        min_col.* = @min(min_col.*, col);
        max_col.* = @max(max_col.*, col);

    }

    fn resolve(self: *Raster, y: i32, clip: Rect, min_col: i32, max_col: i32, writer: anytype) void {

        var acc: i64 = 0;
        var col = min_col;

        while (col <= max_col) : (col += 1) {

            const index: usize = @intCast(col);
            const total = acc * 128 + self.area[index];

            acc += self.cover[index];

            self.area[index] = 0;
            self.cover[index] = 0;

            const magnitude: i64 = @intCast(@abs(total));

            // Linear coverage only: masks/glyphs need exact analytic alpha. Display gamma is applied
            // in SurfaceWriter so compositing masks stay unbiased.
            self.alphas[index] = @intCast(@min(255, @divTrunc(magnitude * 255, full_coverage)));

        }

        // Everything right of the last touched cell inherits the running accumulator (the interior of a
        // shape whose right edge lies past the clip).

        var run_end = max_col;

        if (acc != 0) {

            const tail_alpha: u8 = @intCast(@min(255, @divTrunc(@as(i64, @intCast(@abs(acc * 128))) * 255, full_coverage)));

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

fn midpoint(a: Point, b: Point) Point {

    return .{ .x = (a.x + b.x) >> 1, .y = (a.y + b.y) >> 1 };

}

fn x_at(edge: *const Edge, y: i32) i32 {

    const run = @as(i64, edge.x1 - edge.x0);
    const rise = @as(i64, edge.y1 - edge.y0);

    return edge.x0 + @as(i32, @intCast(round_div(run * (y - edge.y0), rise)));

}

fn y_between(x0: i32, y0: i32, x1: i32, y1: i32, x: i32) i32 {

    const run = @as(i64, x1 - x0);

    if (run == 0) return y1;

    const rise = @as(i64, y1 - y0);
    const interpolated = y0 + @as(i32, @intCast(round_div(rise * (x - x0), run)));

    return std.math.clamp(interpolated, @min(y0, y1), @max(y0, y1));

}

fn round_div(numerator: i64, denominator: i64) i64 {

    if (denominator == 0) return 0;

    const positive = (numerator >= 0 and denominator > 0) or (numerator < 0 and denominator < 0);
    const n = if (numerator < 0) -numerator else numerator;
    const d = if (denominator < 0) -denominator else denominator;
    const q = @divTrunc(n + @divTrunc(d, 2), d);

    return if (positive) q else -q;

}

// Shared instance and the two standard writers. Painting is single-threaded per process (one render thread),
// so one static raster serves the whole program without locking.

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

/// Rasterize `path` into an 8-bit coverage bitmap of `w`x`h` pixels whose top-left is pixel
/// (origin_x, origin_y): the cache path for glyphs, icons, and corner masks.
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

    path.add_rect(path_mod.from_px(2) + 32, path_mod.from_px(0), path_mod.from_px(4), path_mod.from_px(8));

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
