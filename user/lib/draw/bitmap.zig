// Bitmap-font text rendering (07-userspace-ddd.md Section 12.6): parses real console font files in the open
// PC Screen Font formats (PSF1 and PSF2 - the Spleen faces in user/fonts/ ship as one of each), resolves the
// ASCII range through the font's unicode table, and draws 1-bit glyphs with word-wrapped box layout.

const std = @import("std");

const gfx = @import("draw.zig");

pub const Error = error{

    BadFont,

};

const psf1_magic0: u8 = 0x36;
const psf1_magic1: u8 = 0x04;
const psf1_mode_512: u8 = 0x01;
const psf1_mode_table: u8 = 0x02;

const psf2_magic: u32 = 0x864a_b572;
const psf2_flag_table: u32 = 0x01;
const psf2_header_bytes = 32;

pub const Font = struct {

    width: u32,
    height: u32,

    // Bytes per glyph and per glyph row (rows are byte-padded, MSB first).
    glyph_bytes: u32,
    row_bytes: u32,

    count: u32,
    glyphs: []const u8,

    // ASCII codepoint to glyph index, resolved from the unicode table when the file carries one.
    map: [128]u16,

    pub fn parse(bytes: []const u8) Error!Font {

        if (bytes.len >= 4 and bytes[0] == psf1_magic0 and bytes[1] == psf1_magic1) return parse_psf1(bytes);
        if (bytes.len >= psf2_header_bytes and read_u32(bytes, 0) == psf2_magic) return parse_psf2(bytes);

        return error.BadFont;

    }

    pub fn line_height(self: *const Font) i32 {

        return @intCast(self.height + self.height / 4);

    }

    pub fn text_width(self: *const Font, text: []const u8) i32 {

        return @intCast(self.width * @as(u32, @intCast(text.len)));

    }

    pub fn glyph_of(self: *const Font, byte: u8) []const u8 {

        const index: u32 = if (byte < 128) self.map[byte] else self.map['?'];
        const clamped = if (index < self.count) index else 0;
        const start = clamped * self.glyph_bytes;

        return self.glyphs[start .. start + self.glyph_bytes];

    }

    pub fn draw(self: *const Font, surface: *const gfx.Surface, x: i32, y: i32, text: []const u8, color: gfx.Color) void {

        var pen = x;

        for (text) |byte| {

            self.draw_glyph(surface, pen, y, byte, color);

            pen += @intCast(self.width);

        }

    }

    /// Word-wrapped text inside `rect`, clipped to it; returns the height consumed.
    pub fn draw_wrapped(self: *const Font, surface: *const gfx.Surface, rect: gfx.Rect, text: []const u8, color: gfx.Color) i32 {

        const columns = @divTrunc(rect.w, @as(i32, @intCast(self.width)));

        if (columns <= 0) return 0;

        var lines = wrap_lines(text, @intCast(columns));
        var pen_y = rect.y;

        while (lines.next()) |line_text| {

            if (pen_y + @as(i32, @intCast(self.height)) > rect.y + rect.h) break;

            self.draw(surface, rect.x, pen_y, line_text, color);

            pen_y += self.line_height();

        }

        return pen_y - rect.y;

    }

    fn draw_glyph(self: *const Font, surface: *const gfx.Surface, x: i32, y: i32, byte: u8, color: gfx.Color) void {

        const glyph = self.glyph_of(byte);

        var row: u32 = 0;

        while (row < self.height) : (row += 1) {

            var column: u32 = 0;

            while (column < self.width) : (column += 1) {

                const bits = glyph[row * self.row_bytes + column / 8];

                if (bits & (@as(u8, 0x80) >> @intCast(column % 8)) != 0) {

                    surface.put_pixel(x + @as(i32, @intCast(column)), y + @as(i32, @intCast(row)), color);

                }

            }

        }

    }

};

fn parse_psf1(bytes: []const u8) Error!Font {

    const mode = bytes[2];
    const height: u32 = bytes[3];
    const count: u32 = if (mode & psf1_mode_512 != 0) 512 else 256;

    var font = Font{

        .width = 8,
        .height = height,

        .glyph_bytes = height,
        .row_bytes = 1,

        .count = count,
        .glyphs = undefined,

        .map = identity_map(),

    };

    const glyphs_end = 4 + count * height;

    if (height == 0 or bytes.len < glyphs_end) return error.BadFont;

    font.glyphs = bytes[4..glyphs_end];

    if (mode & psf1_mode_table != 0) map_psf1_table(&font, bytes[glyphs_end..]);

    return font;

}

// PSF1 unicode table: per glyph, little-endian u16 codepoints; 0xfffe starts combining sequences (skipped),
// 0xffff terminates the glyph's entry.

fn map_psf1_table(font: *Font, table: []const u8) void {

    var glyph: u16 = 0;
    var offset: usize = 0;
    var in_sequence = false;

    while (offset + 1 < table.len and glyph < font.count) : (offset += 2) {

        const value = std.mem.readInt(u16, table[offset..][0..2], .little);

        if (value == 0xffff) {

            glyph += 1;
            in_sequence = false;

            continue;

        }

        if (value == 0xfffe) {

            in_sequence = true;

            continue;

        }

        if (!in_sequence and value < 128) font.map[value] = glyph;

    }

}

fn parse_psf2(bytes: []const u8) Error!Font {

    const flags = read_u32(bytes, 12);
    const count = read_u32(bytes, 16);
    const glyph_bytes = read_u32(bytes, 20);
    const height = read_u32(bytes, 24);
    const width = read_u32(bytes, 28);

    if (width == 0 or height == 0 or count == 0) return error.BadFont;
    if (glyph_bytes != ((width + 7) / 8) * height) return error.BadFont;

    const header_bytes = read_u32(bytes, 8);
    const glyphs_end = header_bytes + count * glyph_bytes;

    if (bytes.len < glyphs_end) return error.BadFont;

    var font = Font{

        .width = width,
        .height = height,

        .glyph_bytes = glyph_bytes,
        .row_bytes = (width + 7) / 8,

        .count = count,
        .glyphs = bytes[header_bytes..glyphs_end],

        .map = identity_map(),

    };

    if (flags & psf2_flag_table != 0) map_psf2_table(&font, bytes[glyphs_end..]);

    return font;

}

// PSF2 unicode table: per glyph, UTF-8 codepoints; 0xfe starts combining sequences (skipped), 0xff terminates.
// Only the single-byte range matters for the ASCII map, so multi-byte UTF-8 heads are length-skipped.

fn map_psf2_table(font: *Font, table: []const u8) void {

    var glyph: u16 = 0;
    var offset: usize = 0;
    var in_sequence = false;

    while (offset < table.len and glyph < font.count) {

        const byte = table[offset];

        if (byte == 0xff) {

            glyph += 1;
            in_sequence = false;
            offset += 1;

            continue;

        }

        if (byte == 0xfe) {

            in_sequence = true;
            offset += 1;

            continue;

        }

        if (byte < 0x80) {

            if (!in_sequence) font.map[byte] = glyph;

            offset += 1;

        } else {

            offset += std.unicode.utf8ByteSequenceLength(byte) catch 1;

        }

    }

}

fn identity_map() [128]u16 {

    var map: [128]u16 = undefined;

    for (&map, 0..) |*entry, index| {

        entry.* = @intCast(index);

    }

    return map;

}

fn read_u32(bytes: []const u8, offset: usize) u32 {

    return std.mem.readInt(u32, bytes[offset..][0..4], .little);

}

// Greedy word wrap over byte columns: break at the last space that fits, hard-break words longer than a
// line, and honor embedded newlines. Layout is pure so it host-tests without a surface.

pub const LineIterator = struct {

    text: []const u8,
    columns: usize,
    offset: usize = 0,
    done: bool = false,

    pub fn next(self: *LineIterator) ?[]const u8 {

        if (self.done) return null;

        const rest = self.text[self.offset..];

        if (rest.len == 0) {

            self.done = true;

            return if (self.offset == 0) null else rest;

        }

        var length: usize = 0;
        var break_at: ?usize = null;

        while (length < rest.len) : (length += 1) {

            if (rest[length] == '\n') {

                self.offset += length + 1;

                return rest[0..length];

            }

            if (length == self.columns) break;
            if (rest[length] == ' ') break_at = length;

        }

        if (length < rest.len and length == self.columns) {

            // A space right at the column edge is a clean break, not an overflow.

            if (rest[length] == ' ') {

                self.offset += length + 1;

                return rest[0..length];

            }

            // Overflow: cut at the last space, or hard-break a word with no break point.

            if (break_at) |space| {

                self.offset += space + 1;

                return rest[0..space];

            }

            self.offset += self.columns;

            return rest[0..self.columns];

        }

        self.done = true;

        return rest;

    }

};

pub fn wrap_lines(text: []const u8, columns: usize) LineIterator {

    return .{ .text = text, .columns = @max(1, columns) };

}

const testing = std.testing;

test "wrap breaks at spaces and honors newlines" {

    var lines = wrap_lines("the quick brown\nfox jumps", 11);

    try testing.expectEqualStrings("the quick", lines.next().?);
    try testing.expectEqualStrings("brown", lines.next().?);
    try testing.expectEqualStrings("fox jumps", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());

}

test "wrap hard-breaks words longer than a line" {

    var lines = wrap_lines("abcdefgh", 3);

    try testing.expectEqualStrings("abc", lines.next().?);
    try testing.expectEqualStrings("def", lines.next().?);
    try testing.expectEqualStrings("gh", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());

}

test "wrap of an exact fit does not add an empty line" {

    var lines = wrap_lines("abc", 3);

    try testing.expectEqualStrings("abc", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());

}

// A minimal synthetic PSF2: 2 glyphs of 8x2, with a unicode table mapping 'A' to glyph 1.

fn synthetic_psf2() [psf2_header_bytes + 4 + 4]u8 {

    var bytes: [psf2_header_bytes + 4 + 4]u8 = undefined;

    @memset(&bytes, 0);

    std.mem.writeInt(u32, bytes[0..4], psf2_magic, .little);
    std.mem.writeInt(u32, bytes[8..12], psf2_header_bytes, .little); // headersize
    std.mem.writeInt(u32, bytes[12..16], psf2_flag_table, .little); // flags
    std.mem.writeInt(u32, bytes[16..20], 2, .little); // glyph count
    std.mem.writeInt(u32, bytes[20..24], 2, .little); // bytes per glyph
    std.mem.writeInt(u32, bytes[24..28], 2, .little); // height
    std.mem.writeInt(u32, bytes[28..32], 8, .little); // width

    bytes[psf2_header_bytes + 0] = 0x0f; // glyph 0
    bytes[psf2_header_bytes + 2] = 0xf0; // glyph 1

    // Unicode table: glyph 0 <- 'B'; glyph 1 <- 'A'.

    bytes[psf2_header_bytes + 4 + 0] = 'B';
    bytes[psf2_header_bytes + 4 + 1] = 0xff;
    bytes[psf2_header_bytes + 4 + 2] = 'A';
    bytes[psf2_header_bytes + 4 + 3] = 0xff;

    return bytes;

}

test "psf2 parse resolves the unicode table" {

    const bytes = synthetic_psf2();
    const font = try Font.parse(&bytes);

    try testing.expectEqual(@as(u32, 8), font.width);
    try testing.expectEqual(@as(u32, 2), font.height);
    try testing.expectEqual(@as(u16, 1), font.map['A']);
    try testing.expectEqual(@as(u16, 0), font.map['B']);
    try testing.expectEqual(@as(u8, 0xf0), font.glyph_of('A')[0]);

}

test "psf1 parse reads mode and charsize" {

    var bytes: [4 + 256 * 8]u8 = undefined;

    @memset(&bytes, 0);

    bytes[0] = psf1_magic0;
    bytes[1] = psf1_magic1;
    bytes[2] = 0; // 256 glyphs, no table
    bytes[3] = 8; // height

    const font = try Font.parse(&bytes);

    try testing.expectEqual(@as(u32, 8), font.width);
    try testing.expectEqual(@as(u32, 8), font.height);
    try testing.expectEqual(@as(u32, 256), font.count);
    try testing.expectEqual(@as(u16, 'A'), font.map['A']);

}

test "truncated files are rejected" {

    try testing.expectError(error.BadFont, Font.parse(&[_]u8{ 1, 2, 3 }));

    var bytes = synthetic_psf2();

    try testing.expectError(error.BadFont, Font.parse(bytes[0 .. psf2_header_bytes + 2]));

}
