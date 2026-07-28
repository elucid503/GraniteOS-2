// Lightweight JSON helpers for freestanding userspace (key lookup, escape, pretty-print).

const std = @import("std");

pub const Error = error{
    Invalid,
    NoSpaceLeft,
};

/// Locate the first byte of the value after `"key":` (whitespace-tolerant).
pub fn value_start(body: []const u8, key: []const u8) ?usize {

    var needle: [160]u8 = undefined;

    if (key.len + 2 > needle.len) return null;

    needle[0] = '"';
    @memcpy(needle[1..][0..key.len], key);
    needle[1 + key.len] = '"';

    const at = std.mem.indexOf(u8, body, needle[0 .. key.len + 2]) orelse return null;
    var index = at + key.len + 2;

    while (index < body.len and is_space(body[index])) index += 1;

    if (index >= body.len or body[index] != ':') return null;

    index += 1;

    while (index < body.len and is_space(body[index])) index += 1;

    if (index >= body.len) return null;

    return index;

}

/// Copy an unescaped JSON string for `key` into `out`. Returns the written slice.
pub fn string(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {

    const start = value_start(body, key) orelse return null;

    if (body[start] != '"') return null;

    var index = start + 1;
    var written: usize = 0;

    while (index < body.len and written < out.len) {

        const byte = body[index];

        if (byte == '"') break;

        if (byte == '\\' and index + 1 < body.len) {

            index += 1;

            const escape = body[index];

            out[written] = switch (escape) {

                'n', 't', 'r' => ' ',
                'u' => blk: {

                    index += @min(4, body.len - index - 1);

                    break :blk '?';

                },
                else => escape,

            };

            written += 1;
            index += 1;

            continue;

        }

        out[written] = if (byte < 0x20 or byte >= 0x7f) ' ' else byte;
        written += 1;
        index += 1;

    }

    return std.mem.trim(u8, out[0..written], " ");

}

/// Raw number token for `key` (digits, sign, exponent, decimal).
pub fn number_token(body: []const u8, key: []const u8) ?[]const u8 {

    const start = value_start(body, key) orelse return null;
    var end = start;

    while (end < body.len and is_number_byte(body[end])) end += 1;

    if (end == start) return null;

    return body[start..end];

}

pub fn int(body: []const u8, key: []const u8) ?i64 {

    const token = number_token(body, key) orelse return null;

    return std.fmt.parseInt(i64, token, 10) catch null;

}

pub fn float(body: []const u8, key: []const u8) ?f64 {

    const token = number_token(body, key) orelse return null;

    return std.fmt.parseFloat(f64, token) catch null;

}

pub fn uint(body: []const u8, key: []const u8) ?u32 {

    const token = number_token(body, key) orelse return null;

    return std.fmt.parseInt(u32, token, 10) catch null;

}

/// Index of the matching `}` for an object that opens at `open` (`body[open] == '{'`).
pub fn object_end(body: []const u8, open: usize) ?usize {

    if (open >= body.len or body[open] != '{') return null;

    var depth: usize = 0;
    var index = open;
    var in_string = false;
    var escaped = false;

    while (index < body.len) : (index += 1) {

        const byte = body[index];

        if (in_string) {

            if (escaped) {

                escaped = false;

            } else if (byte == '\\') {

                escaped = true;

            } else if (byte == '"') {

                in_string = false;

            }

            continue;

        }

        switch (byte) {

            '"' => in_string = true,
            '{' => depth += 1,

            '}' => {

                depth -= 1;

                if (depth == 0) return index;

            },

            else => {},

        }

    }

    return null;

}

/// True when trimmed text starts with `{` or `[`.
pub fn looks_like(text: []const u8) bool {

    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    return trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[');

}

/// Pretty-print JSON into `out`. Invalid structure falls back to a best-effort pass.
pub fn format(src: []const u8, out: []u8) Error![]const u8 {

    const input = std.mem.trim(u8, src, " \t\r\n");

    if (input.len == 0) return error.Invalid;
    if (!looks_like(input)) return error.Invalid;

    var written: usize = 0;
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;
    var pending_newline = false;

    for (input) |byte| {

        if (in_string) {

            try append_byte(out, &written, byte);

            if (escaped) {

                escaped = false;

            } else if (byte == '\\') {

                escaped = true;

            } else if (byte == '"') {

                in_string = false;

            }

            continue;

        }

        switch (byte) {

            ' ', '\t', '\n', '\r' => {},

            '"' => {

                if (pending_newline) {

                    try newline_indent(out, &written, depth);
                    pending_newline = false;

                }

                try append_byte(out, &written, byte);
                in_string = true;

            },

            '{', '[' => {

                if (pending_newline) {

                    try newline_indent(out, &written, depth);
                    pending_newline = false;

                }

                try append_byte(out, &written, byte);
                depth += 1;
                pending_newline = true;

            },

            '}', ']' => {

                depth -= 1;

                if (depth < 0) return error.Invalid;

                try newline_indent(out, &written, depth);
                try append_byte(out, &written, byte);
                pending_newline = false;

            },

            ',' => {

                try append_byte(out, &written, byte);
                pending_newline = true;

            },

            ':' => {

                try append_byte(out, &written, byte);
                try append_byte(out, &written, ' ');

            },

            else => {

                if (pending_newline) {

                    try newline_indent(out, &written, depth);
                    pending_newline = false;

                }

                try append_byte(out, &written, byte);

            },

        }

    }

    if (depth != 0) return error.Invalid;

    return out[0..written];

}

/// Append a quoted, escaped JSON string (including surrounding quotes).
pub fn append_string(out: []u8, length: *usize, text: []const u8) Error!void {

    try append_slice(out, length, "\"");

    for (text) |byte| {

        switch (byte) {

            '"' => try append_slice(out, length, "\\\""),
            '\\' => try append_slice(out, length, "\\\\"),
            '\n' => try append_slice(out, length, "\\n"),
            '\r' => try append_slice(out, length, "\\r"),
            '\t' => try append_slice(out, length, "\\t"),
            0...8, 11...12, 14...31 => try append_slice(out, length, "?"),

            else => {

                if (length.* >= out.len) return error.NoSpaceLeft;

                out[length.*] = byte;
                length.* += 1;

            },

        }

    }

    try append_slice(out, length, "\"");

}

pub fn is_number_byte(byte: u8) bool {

    return byte == '-' or byte == '+' or byte == '.' or byte == 'e' or byte == 'E' or (byte >= '0' and byte <= '9');

}

fn is_space(byte: u8) bool {

    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';

}

fn append_byte(out: []u8, written: *usize, byte: u8) Error!void {

    if (written.* >= out.len) return error.NoSpaceLeft;

    out[written.*] = byte;
    written.* += 1;

}

fn append_slice(out: []u8, length: *usize, text: []const u8) Error!void {

    if (length.* + text.len > out.len) return error.NoSpaceLeft;

    @memcpy(out[length.*..][0..text.len], text);
    length.* += text.len;

}

fn newline_indent(out: []u8, written: *usize, depth: i32) Error!void {

    try append_byte(out, written, '\n');

    var level: i32 = 0;

    while (level < depth) : (level += 1) {

        try append_slice(out, written, "  ");

    }

}

const testing = std.testing;

test "extracts string int and float" {

    const body = "{\"status\":\"success\",\"offset\":-18000,\"lat\":37.5}";

    var buffer: [32]u8 = undefined;

    try testing.expectEqualStrings("success", string(body, "status", &buffer).?);
    try testing.expectEqual(@as(i64, -18000), int(body, "offset").?);
    try testing.expectEqual(@as(f64, 37.5), float(body, "lat").?);

}

test "pretty formats compact object" {

    var out: [128]u8 = undefined;
    const pretty = try format("{\"ok\":true,\"n\":1}", &out);

    try testing.expect(std.mem.indexOf(u8, pretty, "\n  \"ok\": true") != null);
    try testing.expect(std.mem.indexOf(u8, pretty, "\n  \"n\": 1") != null);

}

test "object_end matches braces" {

    const body = "[{\"a\":1},{\"b\":2}]";
    const open = std.mem.indexOfScalar(u8, body, '{').?;

    try testing.expectEqual(@as(usize, 7), object_end(body, open).?);

}
