// TrueType engine: 26.6 paths, subpixel x-phases, mono grid at phase 0; glyphs cached as 8-bit coverage.

const std = @import("std");

const draw_mod = @import("draw.zig");
const path_mod = @import("path.zig");
const raster = @import("raster.zig");

const Path = path_mod.Path;
const Surface = draw_mod.Surface;

pub const Error = error{
    BadFont,
    MissingTable,
    Unsupported,
};

const max_component_depth = 4;

pub const Face = struct {

    bytes: []const u8,
    cmap: []const u8,
    hmtx: []const u8,
    loca: []const u8,
    glyf: []const u8,

    units_per_em: u16,
    index_to_loc_format: i16,
    glyph_count: u16,
    hmetric_count: u16,

    ascent: i16,
    descent: i16,
    line_gap: i16,

    cmap_format: u16,
    cmap_offset: usize,

    pub fn parse(bytes: []const u8) Error!Face {

        if (bytes.len < 12) return error.BadFont;

        const table_count = read_u16(bytes, 4);

        if (bytes.len < 12 + @as(usize, table_count) * 16) return error.BadFont;

        const cmap = find_table(bytes, "cmap") orelse return error.MissingTable;
        const head = find_table(bytes, "head") orelse return error.MissingTable;
        const hhea = find_table(bytes, "hhea") orelse return error.MissingTable;
        const hmtx = find_table(bytes, "hmtx") orelse return error.MissingTable;
        const maxp = find_table(bytes, "maxp") orelse return error.MissingTable;
        const loca = find_table(bytes, "loca") orelse return error.MissingTable;
        const glyf = find_table(bytes, "glyf") orelse return error.MissingTable;

        if (head.len < 54 or hhea.len < 36 or maxp.len < 6) return error.BadFont;

        const cmap_record = choose_cmap(cmap) orelse return error.Unsupported;

        return .{

            .bytes = bytes,
            .cmap = cmap,
            .hmtx = hmtx,
            .loca = loca,
            .glyf = glyf,

            .units_per_em = read_u16(head, 18),
            .index_to_loc_format = read_i16(head, 50),
            .glyph_count = read_u16(maxp, 4),
            .hmetric_count = read_u16(hhea, 34),

            .ascent = read_i16(hhea, 4),
            .descent = read_i16(hhea, 6),
            .line_gap = read_i16(hhea, 8),

            .cmap_format = cmap_record.format,
            .cmap_offset = cmap_record.offset,

        };

    }

    pub fn line_height(self: *const Face, px: u32) i32 {

        const total = @as(i32, self.ascent) - @as(i32, self.descent) + @as(i32, self.line_gap);

        return @max(@as(i32, @intCast(px)), scale_px(total, px, self.units_per_em));

    }

    pub fn ascent_px(self: *const Face, px: u32) i32 {

        return scale_px(self.ascent, px, self.units_per_em);

    }

    /// Advance width of `text` in 26.6 units.
    pub fn measure(self: *const Face, text: []const u8, px: u32) i32 {

        var width: i32 = 0;
        var offset: usize = 0;

        while (next_codepoint(text, &offset)) |codepoint| {

            width += self.advance(self.glyph_index(codepoint), px);

        }

        return width;

    }

    /// Advance width of `text` in whole pixels, rounded up.
    pub fn text_width(self: *const Face, text: []const u8, px: u32) i32 {

        return @divFloor(self.measure(text, px) + 63, 64);

    }

    /// Fixed cell width for a monospace face: 'M' advance rounded to nearest pixel.
    pub fn mono_width(self: *const Face, px: u32) i32 {

        const advance_fx = self.advance(self.glyph_index('M'), px);

        return @max(1, @divFloor(advance_fx + 32, 64));

    }

    /// Fixed cell height for a monospace grid: ascent-to-descent span, no extra line gap.
    pub fn mono_height(self: *const Face, px: u32) i32 {

        const span = @as(i32, self.ascent) - @as(i32, self.descent);

        return @max(@as(i32, @intCast(px)), scale_px(span, px, self.units_per_em));

    }

    /// Draw with the line box's top-left at (x, y) in pixels; the compatibility entry point.
    pub fn draw(self: *const Face, surface: *const Surface, x: i32, y: i32, px: u32, text: []const u8, color: draw_mod.Color) void {

        self.draw_fx(surface, to_fx(x), to_fx(y + self.ascent_px(px)), px, text, color);

    }

    /// Monospace draw on an integer cell grid at phase 0; pen steps by mono_width, not fractional advance.
    pub fn draw_mono(self: *const Face, surface: *const Surface, x: i32, y: i32, px: u32, text: []const u8, color: draw_mod.Color) void {

        const cell = self.mono_width(px);
        const baseline = y + self.ascent_px(px);
        var pen = x;
        var offset: usize = 0;

        while (next_codepoint(text, &offset)) |codepoint| {

            self.draw_glyph(surface, self.glyph_index(codepoint), to_fx(pen), baseline, px, color);

            pen += cell;

        }

    }

    /// Draw with the baseline at 26.6 coordinates; the pen advances fractionally.
    pub fn draw_fx(self: *const Face, surface: *const Surface, x_fx: i32, baseline_fx: i32, px: u32, text: []const u8, color: draw_mod.Color) void {

        var pen = x_fx;
        const baseline = @divFloor(baseline_fx + 32, 64);
        var offset: usize = 0;

        while (next_codepoint(text, &offset)) |codepoint| {

            const glyph = self.glyph_index(codepoint);

            self.draw_glyph(surface, glyph, pen, baseline, px, color);

            pen += self.advance(glyph, px);

        }

    }

    /// Word-wrapped text inside `rect`, clipped to it; returns the height consumed in pixels.
    pub fn draw_wrapped(self: *const Face, surface: *const Surface, rect: draw_mod.Rect, px: u32, text: []const u8, color: draw_mod.Color) i32 {

        var pen_x = rect.x;
        var pen_y = rect.y;
        const line = self.line_height(px);
        var word = WordIterator{ .text = text };
        const space = self.text_width(" ", px);

        while (word.next()) |part| {

            if (part.newline) {

                pen_x = rect.x;
                pen_y += line;

                continue;

            }

            const part_width = self.text_width(part.bytes, px);

            if (pen_x > rect.x and pen_x + part_width > rect.x + rect.w) {

                pen_x = rect.x;
                pen_y += line;

            }

            if (pen_y + line > rect.y + rect.h) break;

            self.draw(surface, pen_x, pen_y, px, part.bytes, color);

            pen_x += part_width + space;

        }

        return pen_y + line - rect.y;

    }

    pub fn glyph_index(self: *const Face, codepoint: u21) u16 {

        return switch (self.cmap_format) {

            4 => self.glyph_index_format4(codepoint),
            12 => self.glyph_index_format12(codepoint),

            else => 0,

        };

    }

    fn glyph_index_format4(self: *const Face, codepoint: u21) u16 {

        if (codepoint > 0xffff) return 0;

        const table = self.cmap[self.cmap_offset..];

        if (table.len < 16) return 0;

        const seg_count = read_u16(table, 6) / 2;
        const end_codes = 14;
        const start_codes = end_codes + @as(usize, seg_count) * 2 + 2;
        const deltas = start_codes + @as(usize, seg_count) * 2;
        const ranges = deltas + @as(usize, seg_count) * 2;

        if (table.len < ranges + @as(usize, seg_count) * 2) return 0;

        const cp: u16 = @intCast(codepoint);
        var index: usize = 0;

        while (index < seg_count) : (index += 1) {

            const end = read_u16(table, end_codes + index * 2);

            if (cp > end) continue;

            const start = read_u16(table, start_codes + index * 2);

            if (cp < start) return 0;

            const delta = read_i16(table, deltas + index * 2);
            const range = read_u16(table, ranges + index * 2);

            if (range == 0) return wrap_glyph(@as(i32, cp) + @as(i32, delta));

            const mapped_offset = ranges + index * 2 + range + (@as(usize, cp - start) * 2);

            if (mapped_offset + 2 > table.len) return 0;

            const raw = read_u16(table, mapped_offset);

            if (raw == 0) return 0;

            return wrap_glyph(@as(i32, raw) + @as(i32, delta));

        }

        return 0;

    }

    fn glyph_index_format12(self: *const Face, codepoint: u21) u16 {

        const table = self.cmap[self.cmap_offset..];

        if (table.len < 16) return 0;

        const group_count = read_u32(table, 12);
        const cp: usize = @intCast(codepoint);

        var offset: usize = 16;
        var index: usize = 0;

        while (index < group_count and offset + 12 <= table.len) : ({

            index += 1;
            offset += 12;

        }) {

            const start = read_u32(table, offset);
            const end = read_u32(table, offset + 4);
            const glyph = read_u32(table, offset + 8);

            if (cp >= start and cp <= end) return @intCast(@min(glyph + cp - start, @as(usize, std.math.maxInt(u16))));

        }

        return 0;

    }

    /// Glyph advance in 26.6 units.
    fn advance(self: *const Face, glyph: u16, px: u32) i32 {

        if (self.hmetric_count == 0 or self.hmtx.len < 4) return to_fx(@intCast(px));

        const metric_index = @min(glyph, self.hmetric_count - 1);
        const offset = @as(usize, metric_index) * 4;

        if (offset + 2 > self.hmtx.len) return to_fx(@intCast(px));

        return scale_fx(read_u16(self.hmtx, offset), px, self.units_per_em);

    }

    fn draw_glyph(self: *const Face, surface: *const Surface, glyph: u16, pen_fx: i32, baseline: i32, px: u32, color: draw_mod.Color) void {

        const pen_px = @divFloor(pen_fx, 64);
        const fraction = pen_fx - pen_px * 64;
        const phase: u32 = @intCast(@divFloor(fraction, 16));

        if (px >= 6 and px <= cache_max_px) {

            if (cached_glyph(self, glyph, px, phase)) |slot| {

                const entry = glyph_meta[slot];

                if (entry.w != 0) {

                    surface.blend_coverage(pen_px + entry.left, baseline + entry.top, glyph_coverage[slot][0 .. @as(u32, entry.w) * entry.h], entry.w, entry.h, color);

                }

                return;

            }

        }

        // Large or uncacheable glyphs rasterize directly at the exact pen position.

        var path = Path{};

        self.build_glyph_path(&path, glyph, pen_fx, to_fx(baseline), px, 0) catch return;

        raster.fill(surface, &path, color);

    }

    // Outline extraction: on-curve as lines, off-curve as quadratics with implied midpoints.

    fn build_glyph_path(self: *const Face, path: *Path, glyph: u16, origin_x: i32, origin_y: i32, px: u32, depth: u8) Error!void {

        if (depth > max_component_depth) return;

        const slice = self.glyph_slice(glyph) orelse return;

        if (slice.len < 10) return;

        const contours = read_i16(slice, 0);

        if (contours < 0) return self.build_compound_path(path, slice, origin_x, origin_y, px, depth);
        if (contours == 0) return;

        const contour_count: usize = @intCast(contours);

        if (contour_count > max_contours) return error.Unsupported;
        if (slice.len < 10 + contour_count * 2 + 2) return error.BadFont;

        var ends: [max_contours]u16 = undefined;
        var point_count: usize = 0;

        for (0..contour_count) |index| {

            ends[index] = read_u16(slice, 10 + index * 2);
            point_count = @as(usize, ends[index]) + 1;

        }

        if (point_count > max_glyph_points) return error.Unsupported;

        const instructions = read_u16(slice, 10 + contour_count * 2);
        var offset = 10 + contour_count * 2 + 2 + @as(usize, instructions);

        if (offset > slice.len) return error.BadFont;

        var flags: [max_glyph_points]u8 = undefined;
        var point_index: usize = 0;

        while (point_index < point_count) {

            if (offset >= slice.len) return error.BadFont;

            const flag = slice[offset];

            offset += 1;
            flags[point_index] = flag;
            point_index += 1;

            if (flag & 0x08 != 0) {

                if (offset >= slice.len) return error.BadFont;

                const repeat = slice[offset];

                offset += 1;

                var n: u8 = 0;

                while (n < repeat and point_index < point_count) : (n += 1) {

                    flags[point_index] = flag;
                    point_index += 1;

                }

            }

        }

        var xs: [max_glyph_points]i32 = undefined;
        var ys: [max_glyph_points]i32 = undefined;
        var on: [max_glyph_points]bool = undefined;

        var x: i16 = 0;

        for (0..point_count) |index| {

            const flag = flags[index];
            var dx: i16 = 0;

            if (flag & 0x02 != 0) {

                if (offset >= slice.len) return error.BadFont;

                dx = @intCast(slice[offset]);
                offset += 1;

                if (flag & 0x10 == 0) dx = -dx;

            } else if (flag & 0x10 == 0) {

                if (offset + 2 > slice.len) return error.BadFont;

                dx = read_i16(slice, offset);
                offset += 2;

            }

            x +%= dx;
            xs[index] = origin_x + scale_fx(x, px, self.units_per_em);
            on[index] = flag & 0x01 != 0;

        }

        var y: i16 = 0;

        for (0..point_count) |index| {

            const flag = flags[index];
            var dy: i16 = 0;

            if (flag & 0x04 != 0) {

                if (offset >= slice.len) return error.BadFont;

                dy = @intCast(slice[offset]);
                offset += 1;

                if (flag & 0x20 == 0) dy = -dy;

            } else if (flag & 0x20 == 0) {

                if (offset + 2 > slice.len) return error.BadFont;

                dy = read_i16(slice, offset);
                offset += 2;

            }

            y +%= dy;
            ys[index] = origin_y - scale_fx(y, px, self.units_per_em);

        }

        var first: usize = 0;

        for (0..contour_count) |contour| {

            const last = @as(usize, ends[contour]);

            emit_contour(path, xs[first .. last + 1], ys[first .. last + 1], on[first .. last + 1]);

            first = last + 1;

        }

    }

    fn build_compound_path(self: *const Face, path: *Path, glyph: []const u8, origin_x: i32, origin_y: i32, px: u32, depth: u8) Error!void {

        var offset: usize = 10;

        while (offset + 4 <= glyph.len) {

            const flags = read_u16(glyph, offset);
            const child = read_u16(glyph, offset + 2);

            offset += 4;

            var arg1: i16 = 0;
            var arg2: i16 = 0;

            if (flags & 0x0001 != 0) {

                if (offset + 4 > glyph.len) return error.BadFont;

                arg1 = read_i16(glyph, offset);
                arg2 = read_i16(glyph, offset + 2);
                offset += 4;

            } else {

                if (offset + 2 > glyph.len) return error.BadFont;

                arg1 = @as(i16, @as(i8, @bitCast(glyph[offset])));
                arg2 = @as(i16, @as(i8, @bitCast(glyph[offset + 1])));
                offset += 2;

            }

            var scale: i32 = 1 << 14;

            if (flags & 0x0008 != 0) {

                if (offset + 2 > glyph.len) return error.BadFont;

                scale = @intCast(read_i16(glyph, offset));
                offset += 2;

            } else if (flags & 0x0040 != 0) {

                if (offset + 4 > glyph.len) return error.BadFont;

                scale = @intCast(read_i16(glyph, offset));
                offset += 4;

            } else if (flags & 0x0080 != 0) {

                if (offset + 8 > glyph.len) return error.BadFont;

                scale = @intCast(read_i16(glyph, offset));
                offset += 8;

            }

            if (flags & 0x0002 != 0) {

                const child_x = origin_x + scale_fx(arg1, px, self.units_per_em);
                const child_y = origin_y - scale_fx(arg2, px, self.units_per_em);
                const child_px = scaled_px(px, scale);

                try self.build_glyph_path(path, child, child_x, child_y, child_px, depth + 1);

            }

            if (flags & 0x0100 != 0) offset += 2;

            if (offset > glyph.len or flags & 0x0020 == 0) break;

        }

    }

    fn glyph_slice(self: *const Face, glyph: u16) ?[]const u8 {

        if (glyph >= self.glyph_count) return null;

        const start = self.glyph_offset(glyph);
        const end = self.glyph_offset(glyph + 1);

        if (start >= end or end > self.glyf.len) return null;

        return self.glyf[start..end];

    }

    fn glyph_offset(self: *const Face, glyph: u16) usize {

        if (self.index_to_loc_format == 0) {

            const offset = @as(usize, glyph) * 2;

            if (offset + 2 > self.loca.len) return self.glyf.len;

            return @as(usize, read_u16(self.loca, offset)) * 2;

        }

        const offset = @as(usize, glyph) * 4;

        if (offset + 4 > self.loca.len) return self.glyf.len;

        return read_u32(self.loca, offset);

    }

};

const max_contours = 64;
const max_glyph_points = 512;

fn emit_contour(path: *Path, xs: []const i32, ys: []const i32, on: []const bool) void {

    const count = xs.len;

    if (count == 0) return;

    const last = count - 1;

    // The start point: the first on-curve point, or the implied midpoint when the contour opens off-curve.

    var start_x: i32 = undefined;
    var start_y: i32 = undefined;
    var index: usize = 0;

    if (on[0]) {

        start_x = xs[0];
        start_y = ys[0];
        index = 1;

    } else if (on[last]) {

        start_x = xs[last];
        start_y = ys[last];

    } else {

        start_x = (xs[last] + xs[0]) >> 1;
        start_y = (ys[last] + ys[0]) >> 1;

    }

    path.move_to(fx(start_x), fx(start_y));

    var processed: usize = 0;

    while (processed < count) {

        const i = index % count;

        if (on[i]) {

            path.line_to(fx(xs[i]), fx(ys[i]));

            index += 1;
            processed += 1;

            continue;

        }

        const next = (index + 1) % count;

        if (processed + 1 < count and !on[next]) {

            const mid_x = (xs[i] + xs[next]) >> 1;
            const mid_y = (ys[i] + ys[next]) >> 1;

            path.quad_to(fx(xs[i]), fx(ys[i]), fx(mid_x), fx(mid_y));

            index += 1;
            processed += 1;

        } else if (processed + 1 < count) {

            path.quad_to(fx(xs[i]), fx(ys[i]), fx(xs[next]), fx(ys[next]));

            index += 2;
            processed += 2;

        } else {

            path.quad_to(fx(xs[i]), fx(ys[i]), fx(start_x), fx(start_y));

            index += 1;
            processed += 1;

        }

    }

    path.close();

}

// Glyph cache keyed by face, glyph, px, phase; face tag avoids Inter/mono slot collisions; single-threaded.

// Cache size tuned to Flint's 4 MiB child_budget so welcome/taskbar still spawn.
const cache_max_px: u32 = 32;
const cache_box_w: u32 = 40;
const cache_box_h: u32 = 46;
const cache_capacity: usize = 1024;

const GlyphEntry = struct {

    used: bool = false,
    key: u32 = 0,
    used_at: u32 = 0,

    left: i16 = 0,
    top: i16 = 0,

    w: u16 = 0,
    h: u16 = 0,

};

var glyph_meta = [_]GlyphEntry{.{}} ** cache_capacity;
var glyph_coverage: [cache_capacity][cache_box_w * cache_box_h]u8 = undefined;
var glyph_clock: u32 = 0;

fn face_tag(face: *const Face) u32 {

    // Mix the font blob address so Inter and JetBrains Mono never share a cache slot by glyph id alone.
    return @truncate(@intFromPtr(face.bytes.ptr) *% 0x9e3779b1);

}

fn glyph_key(face: *const Face, glyph: u16, px: u32, phase: u32) u32 {

    return face_tag(face) ^ (@as(u32, glyph) << 10) ^ (px << 2) ^ phase;

}

fn cached_glyph(face: *const Face, glyph: u16, px: u32, phase: u32) ?usize {

    const key = glyph_key(face, glyph, px, phase);
    const start = key % cache_capacity;

    var probe: usize = 0;
    var slot = start;
    var oldest_slot = start;
    var oldest_use: u32 = std.math.maxInt(u32);

    while (probe < 16) : (probe += 1) {

        const entry = &glyph_meta[slot];

        if (entry.used and entry.key == key) {

            touch_glyph(entry);

            return slot;

        }

        if (!entry.used) return if (rasterize_into(face, slot, glyph, px, phase, key)) slot else null;

        if (entry.used_at < oldest_use) {

            oldest_use = entry.used_at;
            oldest_slot = slot;

        }

        slot = (slot + 1) % cache_capacity;

    }

    return if (rasterize_into(face, oldest_slot, glyph, px, phase, key)) oldest_slot else null;

}

fn touch_glyph(entry: *GlyphEntry) void {

    glyph_clock +%= 1;
    entry.used_at = glyph_clock;

}

fn rasterize_into(face: *const Face, slot: usize, glyph: u16, px: u32, phase: u32, key: u32) bool {

    var path = Path{};

    // The glyph sits at origin with the pen shifted by the subpixel phase (quarters of a pixel).

    face.build_glyph_path(&path, glyph, @intCast(phase * 16), 0, px, 0) catch return false;

    if (path.overflowed) return false;

    if (path.point_count == 0) {

        glyph_meta[slot] = .{ .used = true, .key = key };
        touch_glyph(&glyph_meta[slot]);

        return true;

    }

    var min_x: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);

    for (path.points[0..path.point_count]) |point| {

        min_x = @min(min_x, point.x);
        max_x = @max(max_x, point.x);
        min_y = @min(min_y, point.y);
        max_y = @max(max_y, point.y);

    }

    const x0: i32 = @intFromFloat(@floor(min_x));
    const y0: i32 = @intFromFloat(@floor(min_y));
    const w: i32 = @as(i32, @intFromFloat(@ceil(max_x))) - x0 + 1;
    const h: i32 = @as(i32, @intFromFloat(@ceil(max_y))) - y0 + 1;

    if (w <= 0 or h <= 0) {

        glyph_meta[slot] = .{ .used = true, .key = key };
        touch_glyph(&glyph_meta[slot]);

        return true;

    }

    if (w > cache_box_w or h > cache_box_h) return false;

    const cells: u32 = @intCast(w * h);

    @memset(glyph_coverage[slot][0..cells], 0);

    raster.fill_coverage(&path, glyph_coverage[slot][0..cells], @intCast(w), @intCast(h), x0, y0);

    if (px <= stem_darken_max_px) darken_stems(glyph_coverage[slot][0..cells]);

    glyph_meta[slot] = .{

        .used = true,
        .key = key,

        .left = @intCast(x0),
        .top = @intCast(y0),

        .w = @intCast(w),
        .h = @intCast(h),

    };

    touch_glyph(&glyph_meta[slot]);

    return true;

}

// Stem darkening lifts split-stem midtones at small sizes without moving edges or changing phase/advances.

const stem_darken_max_px: u32 = 16;
const stem_gain: u32 = 220;

fn darken_stems(coverage: []u8) void {

    for (coverage) |*cell| {

        const a: u32 = cell.*;

        if (a == 0 or a == 255) continue;

        // Quadratic lift: strongest around half coverage (split stems), gentle near the extremes.
        const lifted = a + @divTrunc(a * (255 - a) * stem_gain, 255 * 255);

        cell.* = @intCast(@min(@as(u32, 255), lifted));

    }

}

fn choose_cmap(cmap: []const u8) ?CmapRecord {

    if (cmap.len < 4) return null;

    const count = read_u16(cmap, 2);
    var fallback: ?CmapRecord = null;

    var index: usize = 0;

    while (index < count) : (index += 1) {

        const record_offset = 4 + index * 8;

        if (record_offset + 8 > cmap.len) return null;

        const platform = read_u16(cmap, record_offset);
        const encoding = read_u16(cmap, record_offset + 2);
        const subtable_offset = read_u32(cmap, record_offset + 4);

        if (subtable_offset + 2 > cmap.len) continue;

        const format = read_u16(cmap, subtable_offset);

        if (format != 4 and format != 12) continue;

        const found = CmapRecord{ .format = format, .offset = subtable_offset };

        if (platform == 3 and (encoding == 1 or encoding == 10)) return found;
        if (fallback == null) fallback = found;

    }

    return fallback;

}

const CmapRecord = struct {

    format: u16,
    offset: usize,

};

fn find_table(bytes: []const u8, tag: []const u8) ?[]const u8 {

    const table_count = read_u16(bytes, 4);

    var index: usize = 0;

    while (index < table_count) : (index += 1) {

        const offset = 12 + index * 16;

        if (offset + 16 > bytes.len) return null;
        if (!std.mem.eql(u8, bytes[offset .. offset + 4], tag)) continue;

        const start = read_u32(bytes, offset + 8);
        const length = read_u32(bytes, offset + 12);

        if (start + length > bytes.len) return null;

        return bytes[start .. start + length];

    }

    return null;

}

/// Scale a font-unit metric to whole pixels, rounding to nearest.
fn scale_px(value: anytype, px: u32, units: u16) i32 {

    if (units == 0) return 0;

    return @intCast(round_div(@as(i64, @intCast(value)) * px, units));

}

// Glyph outlines stay 26.6 internally for the subpixel phase cache; the path tape takes pixels.
fn fx(value: i32) f32 {

    return @as(f32, @floatFromInt(value)) / 64.0;

}

fn to_fx(px: i32) i32 {

    return px * 64;

}

/// Scale a font-unit metric to 26.6.
fn scale_fx(value: anytype, px: u32, units: u16) i32 {

    if (units == 0) return 0;

    return @intCast(round_div(@as(i64, @intCast(value)) * px * 64, units));

}

fn scaled_px(px: u32, scale: i32) u32 {

    if (scale <= 0) return px;

    return @max(1, @as(u32, @intCast(round_div(@as(i64, px) * scale, 1 << 14))));

}

fn round_div(numerator: i64, denominator_in: i64) i64 {

    const denominator = @max(1, denominator_in);
    const half = @divTrunc(denominator, 2);

    if (numerator >= 0) return @divTrunc(numerator + half, denominator);

    return -@divTrunc(-numerator + half, denominator);

}

fn wrap_glyph(value: i32) u16 {

    return @intCast(@mod(value, 65536));

}

fn read_u16(bytes: []const u8, offset: usize) u16 {

    return std.mem.readInt(u16, bytes[offset..][0..2], .big);

}

fn read_i16(bytes: []const u8, offset: usize) i16 {

    return std.mem.readInt(i16, bytes[offset..][0..2], .big);

}

fn read_u32(bytes: []const u8, offset: usize) usize {

    return @intCast(std.mem.readInt(u32, bytes[offset..][0..4], .big));

}

fn next_codepoint(text: []const u8, offset: *usize) ?u21 {

    if (offset.* >= text.len) return null;

    const rest = text[offset.*..];
    const length = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;

    if (length == 1 or length > rest.len) {

        offset.* += 1;

        return rest[0];

    }

    const codepoint = std.unicode.utf8Decode(rest[0..length]) catch rest[0];

    offset.* += length;

    return codepoint;

}

const Word = struct {

    bytes: []const u8,
    newline: bool = false,

};

const WordIterator = struct {

    text: []const u8,
    offset: usize = 0,

    fn next(self: *WordIterator) ?Word {

        while (self.offset < self.text.len and self.text[self.offset] == ' ') self.offset += 1;

        if (self.offset >= self.text.len) return null;

        if (self.text[self.offset] == '\n') {

            self.offset += 1;

            return .{ .bytes = "", .newline = true };

        }

        const start = self.offset;

        while (self.offset < self.text.len and self.text[self.offset] != ' ' and self.text[self.offset] != '\n') self.offset += 1;

        return .{ .bytes = self.text[start..self.offset] };

    }

};

const testing = std.testing;

test "word iterator keeps explicit newlines" {

    var words = WordIterator{ .text = "a b\nc" };

    try testing.expectEqualStrings("a", words.next().?.bytes);
    try testing.expectEqualStrings("b", words.next().?.bytes);
    try testing.expect(words.next().?.newline);
    try testing.expectEqualStrings("c", words.next().?.bytes);
    try testing.expectEqual(@as(?Word, null), words.next());

}

test "stem darkening lifts midtones and pins the extremes" {

    var cells = [_]u8{ 0, 40, 128, 220, 255 };

    darken_stems(&cells);

    try testing.expectEqual(@as(u8, 0), cells[0]);
    try testing.expectEqual(@as(u8, 255), cells[4]);

    try testing.expect(cells[1] > 40);
    try testing.expect(cells[2] > 128);
    try testing.expect(cells[3] > 220);

}

test "truncated fonts are rejected" {

    try testing.expectError(error.BadFont, Face.parse(&[_]u8{ 1, 2, 3 }));

}

test "JetBrains Mono parses as a monospace face" {

    const allocator = testing.allocator;
    const bytes = std.fs.cwd().readFileAlloc(allocator, "user/fonts/JetBrainsMono-Regular.ttf", 512 * 1024) catch return error.SkipZigTest;

    defer allocator.free(bytes);

    const face = try Face.parse(bytes);

    try testing.expect(face.units_per_em > 0);
    try testing.expect(face.glyph_count > 0);

    const px: u32 = 13;
    const cell = face.mono_width(px);

    try testing.expect(cell >= 6 and cell <= 12);
    try testing.expectEqual(cell, @divFloor(face.advance(face.glyph_index('i'), px) + 32, 64));
    try testing.expectEqual(cell, @divFloor(face.advance(face.glyph_index('W'), px) + 32, 64));
    try testing.expect(face.mono_height(px) >= @as(i32, @intCast(px)));

}
