// Minimal TrueType text renderer: parses the table directory, cmap, metrics, loca, and simple glyf outlines,
// then scan-converts quadratic contours into XRGB surfaces. It is intentionally small and allocation-free.

const std = @import("std");

const gfx = @import("gfx.zig");

pub const Error = error{
    BadFont,
    MissingTable,
    Unsupported,
};

const max_points = 512;
const max_segments = 1024;
const max_contours = 64;
const max_intersections = 256;
const fill_samples = 4;

const Point = struct {
    x: i32,
    y: i32,
    on: bool,
};

const Segment = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

const Intersection = struct {
    x: i32,
    winding: i8,
};

pub const Face = struct {
    bytes: []const u8,
    cmap: []const u8,
    head: []const u8,
    hhea: []const u8,
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
            .head = head,
            .hhea = hhea,
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
        return @max(@as(i32, @intCast(px)), scale_metric(total, px, self.units_per_em));
    }

    pub fn text_width(self: *const Face, text: []const u8, px: u32) i32 {
        var width: i32 = 0;
        var offset: usize = 0;

        while (next_codepoint(text, &offset)) |codepoint| {
            width += self.advance(self.glyph_index(codepoint), px);
        }

        return width;
    }

    pub fn draw(self: *const Face, surface: *const gfx.Surface, x: i32, y: i32, px: u32, text: []const u8, color: gfx.Color) void {
        var pen = x;
        const baseline = y + scale_metric(self.ascent, px, self.units_per_em);
        var offset: usize = 0;

        while (next_codepoint(text, &offset)) |codepoint| {
            const glyph = self.glyph_index(codepoint);

            self.draw_glyph(surface, glyph, pen, baseline, px, color);
            pen += self.advance(glyph, px);
        }
    }

    pub fn draw_wrapped(self: *const Face, surface: *const gfx.Surface, rect: gfx.Rect, px: u32, text: []const u8, color: gfx.Color) i32 {
        var pen_x = rect.x;
        var pen_y = rect.y;
        const line = self.line_height(px);
        var word = WordIterator{ .text = text };

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
            pen_x += part_width + self.text_width(" ", px);
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
        var offset: usize = 16;

        const cp: usize = @intCast(codepoint);
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

    fn advance(self: *const Face, glyph: u16, px: u32) i32 {
        if (self.hmetric_count == 0 or self.hmtx.len < 4) return @intCast(px);

        const metric_index = @min(glyph, self.hmetric_count - 1);
        const offset = @as(usize, metric_index) * 4;

        if (offset + 2 > self.hmtx.len) return @intCast(px);

        return scale_metric(read_u16(self.hmtx, offset), px, self.units_per_em);
    }

    fn draw_glyph(self: *const Face, surface: *const gfx.Surface, glyph: u16, pen_x: i32, baseline: i32, px: u32, color: gfx.Color) void {
        var segments: [max_segments]Segment = undefined;
        var count: usize = 0;

        self.build_glyph_segments(glyph, pen_x * 64, baseline * 64, px, 0, &segments, &count) catch return;

        fill_segments(surface, segments[0..count], color);
    }

    fn build_glyph_segments(
        self: *const Face,
        glyph: u16,
        origin_x: i32,
        origin_y: i32,
        px: u32,
        depth: u8,
        segments: *[max_segments]Segment,
        count: *usize,
    ) Error!void {
        if (depth > 4) return;

        const slice = self.glyph_slice(glyph) orelse return;
        if (slice.len < 10) return;

        const contours = read_i16(slice, 0);

        if (contours < 0) {
            try self.build_compound_segments(slice, origin_x, origin_y, px, depth, segments, count);
            return;
        }

        if (contours == 0) return;
        if (contours > max_contours) return error.Unsupported;

        const contour_count: usize = @intCast(contours);
        if (slice.len < 10 + contour_count * 2 + 2) return error.BadFont;

        var ends: [max_contours]u16 = undefined;
        var point_count: usize = 0;

        for (0..contour_count) |index| {
            ends[index] = read_u16(slice, 10 + index * 2);
            point_count = @as(usize, ends[index]) + 1;
        }

        if (point_count > max_points) return error.Unsupported;

        const instructions = read_u16(slice, 10 + contour_count * 2);
        var offset = 10 + contour_count * 2 + 2 + @as(usize, instructions);
        if (offset > slice.len) return error.BadFont;

        var flags: [max_points]u8 = undefined;
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

        var points: [max_points]Point = undefined;
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
            points[index].x = origin_x + scale_metric_26_6(x, px, self.units_per_em);
            points[index].on = flag & 0x01 != 0;
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
            points[index].y = origin_y - scale_metric_26_6(y, px, self.units_per_em);
        }

        var first: usize = 0;

        for (0..contour_count) |contour| {
            const last = @as(usize, ends[contour]);

            flatten_contour(points[first .. last + 1], segments, count);
            first = last + 1;
        }
    }

    fn build_compound_segments(
        self: *const Face,
        glyph: []const u8,
        origin_x: i32,
        origin_y: i32,
        px: u32,
        depth: u8,
        segments: *[max_segments]Segment,
        count: *usize,
    ) Error!void {
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
                const child_x = origin_x + scale_metric_26_6(arg1, px, self.units_per_em);
                const child_y = origin_y - scale_metric_26_6(arg2, px, self.units_per_em);
                const child_px = scaled_px(px, scale);

                try self.build_glyph_segments(child, child_x, child_y, child_px, depth + 1, segments, count);
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

const CmapRecord = struct {
    format: u16,
    offset: usize,
};

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
        if (platform == 0) fallback = found;
        if (fallback == null) fallback = found;
    }

    return fallback;
}

fn flatten_contour(points: []const Point, segments: *[max_segments]Segment, count: *usize) void {
    if (points.len == 0) return;

    const last_index = points.len - 1;
    var current = if (points[0].on) points[0] else if (points[last_index].on) points[last_index] else midpoint(points[last_index], points[0]);
    const start = current;
    var index: usize = if (points[0].on) 1 else 0;
    var processed: usize = 0;

    while (processed < points.len) {
        const p = points[index % points.len];

        if (p.on) {
            add_segment(segments, count, current, p);
            current = p;
            index += 1;
            processed += 1;
            continue;
        }

        const next = points[(index + 1) % points.len];

        if (next.on) {
            add_quadratic(segments, count, current, p, next);
            current = next;
            index += 2;
            processed += 2;
        } else {
            const implied = midpoint(p, next);
            add_quadratic(segments, count, current, p, implied);
            current = implied;
            index += 1;
            processed += 1;
        }
    }

    add_segment(segments, count, current, start);
}

fn add_segment(segments: *[max_segments]Segment, count: *usize, a: Point, b: Point) void {
    if (count.* >= segments.len) return;
    if (a.x == b.x and a.y == b.y) return;

    segments[count.*] = .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y };
    count.* += 1;
}

fn add_quadratic(segments: *[max_segments]Segment, count: *usize, a: Point, b: Point, c: Point) void {
    const steps: i32 = 12;
    var last = a;
    var step: i32 = 1;

    while (step <= steps) : (step += 1) {
        const t = step;
        const mt = steps - step;
        const denom = steps * steps;
        const point = Point{
            .x = @divTrunc(mt * mt * a.x + 2 * mt * t * b.x + t * t * c.x, denom),
            .y = @divTrunc(mt * mt * a.y + 2 * mt * t * b.y + t * t * c.y, denom),
            .on = true,
        };

        add_segment(segments, count, last, point);
        last = point;
    }
}

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2), .on = true };
}

fn fill_segments(surface: *const gfx.Surface, segments: []const Segment, color: gfx.Color) void {
    if (segments.len == 0) return;

    var min_y: i32 = std.math.maxInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);

    for (segments) |segment| {
        min_x = @min(min_x, @min(segment.x0, segment.x1));
        max_x = @max(max_x, @max(segment.x0, segment.x1));
        min_y = @min(min_y, @min(segment.y0, segment.y1));
        max_y = @max(max_y, @max(segment.y0, segment.y1));
    }

    const surface_rect = surface.bounds();
    const x_start = @max(surface_rect.x, @divFloor(min_x, 64) - 1);
    const x_end = @min(@min(surface_rect.x + surface_rect.w - 1, @divFloor(max_x + 63, 64) + 1), x_start + max_intersections - 1);

    if (x_start > x_end) return;

    var y = @max(surface_rect.y, @divFloor(min_y, 64) - 1);
    const y_end = @min(surface_rect.y + surface_rect.h, @divFloor(max_y + 63, 64) + 1);
    const sample_offsets = [_]i32{ 8, 24, 40, 56 };

    while (y < y_end) : (y += 1) {

        var coverage: [max_intersections]u8 = [_]u8{0} ** max_intersections;

        for (sample_offsets) |sample_y| {

            const scan = y * 64 + sample_y;
            var intersections: [max_intersections]Intersection = undefined;
            var count: usize = 0;

            for (segments) |segment| {
                const y0 = segment.y0;
                const y1 = segment.y1;

                if (y0 == y1) continue;
                if (scan < @min(y0, y1) or scan >= @max(y0, y1)) continue;
                if (count >= intersections.len) break;

                intersections[count] = .{
                    .x = segment.x0 + @as(i32, @intCast(@divTrunc(@as(i64, scan - y0) * @as(i64, segment.x1 - segment.x0), @as(i64, y1 - y0)))),
                    .winding = if (y1 > y0) 1 else -1,
                };
                count += 1;
            }

            sort_intersections(intersections[0..count]);

            var index: usize = 0;
            var winding: i32 = 0;
            var span_start: ?i32 = null;

            while (index < count) : (index += 1) {

                const was_inside = winding != 0;

                winding += @as(i32, intersections[index].winding);

                const is_inside = winding != 0;

                if (!was_inside and is_inside) {

                    span_start = intersections[index].x;

                } else if (was_inside and !is_inside) {

                    if (span_start) |left| {

                        const right = intersections[index].x;

                        if (right > left) accumulate_span(&coverage, x_start, x_end, left, right);

                    }

                    span_start = null;

                }

            }

        }

        var x = x_start;
        while (x <= x_end) : (x += 1) {

            const coverage_index: usize = @intCast(x - x_start);
            const covered = coverage[coverage_index];

            if (covered != 0) surface.blend_pixel(x, y, color, @intCast((@as(u32, covered) * 255) / (fill_samples * fill_samples)));

        }
    }
}

fn accumulate_span(coverage: *[max_intersections]u8, x_start: i32, x_end: i32, left: i32, right: i32) void {

    const first_x = @max(x_start, @divFloor(left, 64));
    const last_x = @min(x_end, @divFloor(right + 63, 64));
    const sample_offsets = [_]i32{ 8, 24, 40, 56 };

    var x = first_x;

    while (x <= last_x) : (x += 1) {

        const coverage_index: usize = @intCast(x - x_start);

        if (coverage_index >= coverage.len) break;

        var covered: u8 = 0;

        for (sample_offsets) |sample_x| {

            const sx = x * 64 + sample_x;

            if (sx >= left and sx < right) covered += 1;

        }

        const total = @as(u16, coverage[coverage_index]) + covered;

        coverage[coverage_index] = @intCast(@min(total, fill_samples * fill_samples));

    }

}

fn sort_intersections(values: []Intersection) void {

    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const value = values[i];
        var j = i;

        while (j > 0 and values[j - 1].x > value.x) : (j -= 1) {
            values[j] = values[j - 1];
        }

        values[j] = value;
    }

}

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

fn scale_metric(value: anytype, px: u32, units: u16) i32 {

    if (units == 0) return 0;

    const v: i64 = @intCast(value);

    return round_div_i64(v * @as(i64, px), units);
}

fn scale_metric_26_6(value: anytype, px: u32, units: u16) i32 {

    if (units == 0) return 0;

    const numerator = @as(i64, @intCast(value)) * @as(i64, px) * 64;

    return round_div_i64(numerator, units);

}

fn scaled_px(px: u32, scale: i32) u32 {

    if (scale <= 0) return px;

    const numerator = @as(i64, px) * scale;

    return @max(1, @as(u32, @intCast(round_div_i64(numerator, 1 << 14))));

}

fn round_div_i64(numerator: i64, denominator_in: i64) i32 {

    const denominator = @max(1, denominator_in);
    const half = @divTrunc(denominator, 2);
    const rounded = if (numerator >= 0)
        @divTrunc(numerator + half, denominator)
    else
        -@divTrunc(-numerator + half, denominator);

    return @intCast(rounded);

}

fn read_u16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn read_i16(bytes: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, bytes[offset..][0..2], .big);
}

fn wrap_glyph(value: i32) u16 {

    return @intCast(@mod(value, 65536));

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
