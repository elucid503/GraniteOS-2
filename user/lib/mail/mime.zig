// MIME helpers: decode headers, walk multipart, emit UTF-8 text.

const std = @import("std");

const max_depth = 3;

pub const Body = struct {

    text: []const u8,
    html: bool = false,
    truncated: bool = false,

};

/// Split a message into its header block and body at the first blank line.
pub fn split(message: []const u8) struct { headers: []const u8, body: []const u8 } {

    if (std.mem.indexOf(u8, message, "\r\n\r\n")) |at| {

        return .{ .headers = message[0..at], .body = message[at + 4 ..] };

    }

    if (std.mem.indexOf(u8, message, "\n\n")) |at| {

        return .{ .headers = message[0..at], .body = message[at + 2 ..] };

    }

    return .{ .headers = message, .body = "" };

}

/// The raw value of `name` from a header block, with continuation lines folded into one line.
pub fn header(headers: []const u8, name: []const u8, out: []u8) ?[]const u8 {

    var offset: usize = 0;

    while (offset < headers.len) {

        const line_end = line_break(headers, offset);
        const line = headers[offset..line_end];

        offset = next_line(headers, line_end);

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;

        var written = copy_trimmed(out, line[colon + 1 ..], 0);

        // Continuation lines start with whitespace and belong to this field.
        while (offset < headers.len and (headers[offset] == ' ' or headers[offset] == '\t')) {

            const end = line_break(headers, offset);

            if (written < out.len) {

                out[written] = ' ';
                written += 1;

            }

            written = copy_trimmed(out, headers[offset..end], written);
            offset = next_line(headers, end);

        }

        return std.mem.trim(u8, out[0..written], " \t");

    }

    return null;

}

fn copy_trimmed(out: []u8, text: []const u8, start: usize) usize {

    const trimmed = std.mem.trim(u8, text, " \t\r");
    const length = @min(trimmed.len, out.len - @min(start, out.len));

    @memcpy(out[start..][0..length], trimmed[0..length]);

    return start + length;

}

fn line_break(text: []const u8, offset: usize) usize {

    var index = offset;

    while (index < text.len and text[index] != '\n') index += 1;

    if (index > offset and text[index - 1] == '\r') return index - 1;

    return index;

}

fn next_line(text: []const u8, break_at: usize) usize {

    var index = break_at;

    while (index < text.len and text[index] != '\n') index += 1;

    return @min(index + 1, text.len);

}

/// Decode RFC 2047 encoded words ("=?UTF-8?B?...?=") in a header value, leaving the rest as is.
pub fn decode_words(raw: []const u8, out: []u8) []const u8 {

    var written: usize = 0;
    var index: usize = 0;

    while (index < raw.len and written < out.len) {

        if (raw[index] == '=' and index + 1 < raw.len and raw[index + 1] == '?') {

            if (decode_word(raw[index..], out[written..])) |word| {

                written += word.length;
                index += word.consumed;

                continue;

            }

        }

        out[written] = raw[index];

        written += 1;
        index += 1;

    }

    return out[0..written];

}

const Word = struct {

    consumed: usize,
    length: usize,

};

fn decode_word(raw: []const u8, out: []u8) ?Word {

    const charset_end = std.mem.indexOfScalarPos(u8, raw, 2, '?') orelse return null;
    const charset = raw[2..charset_end];

    if (charset_end + 3 >= raw.len or raw[charset_end + 2] != '?') return null;

    const encoding = raw[charset_end + 1];
    const payload_start = charset_end + 3;
    const terminator = std.mem.indexOfPos(u8, raw, payload_start, "?=") orelse return null;
    const payload = raw[payload_start..terminator];

    var decoded: [512]u8 = undefined;

    const length = switch (encoding) {

        'B', 'b' => decode_base64(payload, &decoded),
        'Q', 'q' => decode_quoted(payload, &decoded, true),

        else => return null,

    };

    const latin1 = std.ascii.eqlIgnoreCase(charset, "iso-8859-1") or std.ascii.eqlIgnoreCase(charset, "windows-1252");
    const written = if (latin1) latin1_to_utf8(decoded[0..length], out) else copy_utf8(decoded[0..length], out);

    return .{ .consumed = terminator + 2, .length = written };

}

fn copy_utf8(input: []const u8, out: []u8) usize {

    const length = @min(input.len, out.len);

    @memcpy(out[0..length], input[0..length]);

    return length;

}

fn latin1_to_utf8(input: []const u8, out: []u8) usize {

    var written: usize = 0;

    for (input) |byte| {

        if (byte < 0x80) {

            if (written >= out.len) break;

            out[written] = byte;
            written += 1;

            continue;

        }

        if (written + 2 > out.len) break;

        out[written] = 0xc0 | (byte >> 6);
        out[written + 1] = 0x80 | (byte & 0x3f);
        written += 2;

    }

    return written;

}

pub fn decode_base64(input: []const u8, out: []u8) usize {

    var written: usize = 0;
    var accumulator: u32 = 0;
    var bits: u5 = 0;

    for (input) |byte| {

        const value: u32 = switch (byte) {

            'A'...'Z' => byte - 'A',
            'a'...'z' => byte - 'a' + 26,
            '0'...'9' => byte - '0' + 52,
            '+' => 62,
            '/' => 63,

            // Padding, newlines and stray bytes all just end or skip a group.
            else => continue,

        };

        accumulator = (accumulator << 6) | value;
        bits += 6;

        if (bits >= 8) {

            bits -= 8;

            if (written >= out.len) break;

            out[written] = @truncate(accumulator >> bits);
            written += 1;

        }

    }

    return written;

}

/// Quoted-printable. In headers ("word" mode) an underscore stands for a space.
pub fn decode_quoted(input: []const u8, out: []u8, word: bool) usize {

    var written: usize = 0;
    var index: usize = 0;

    while (index < input.len and written < out.len) {

        const byte = input[index];

        if (byte == '=' and index + 1 < input.len) {

            // A trailing "=" before a line break is a soft break and disappears.
            if (input[index + 1] == '\r' or input[index + 1] == '\n') {

                index += if (index + 2 < input.len and input[index + 1] == '\r' and input[index + 2] == '\n') 3 else 2;

                continue;

            }

            if (index + 2 < input.len) {

                if (hex(input[index + 1])) |high| {

                    if (hex(input[index + 2])) |low| {

                        out[written] = high * 16 + low;

                        written += 1;
                        index += 3;

                        continue;

                    }

                }

            }

        }

        out[written] = if (word and byte == '_') ' ' else byte;

        written += 1;
        index += 1;

    }

    return written;

}

fn hex(byte: u8) ?u8 {

    return switch (byte) {

        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,

        else => null,

    };

}

/// Find the first readable text part of `message` and decode it into `out`.
pub fn extract_body(message: []const u8, out: []u8) Body {

    const parts = split(message);

    return walk(parts.headers, parts.body, out, 0);

}

fn walk(headers: []const u8, body: []const u8, out: []u8, depth: usize) Body {

    var scratch: [256]u8 = undefined;

    const content_type = header(headers, "content-type", &scratch) orelse "text/plain";

    if (depth < max_depth and std.ascii.startsWithIgnoreCase(content_type, "multipart/")) {

        var boundary_storage: [128]u8 = undefined;
        const boundary = parameter(content_type, "boundary", &boundary_storage) orelse return .{ .text = "" };

        return walk_multipart(body, boundary, out, depth);

    }

    const html = std.ascii.startsWithIgnoreCase(content_type, "text/html");

    if (!std.ascii.startsWithIgnoreCase(content_type, "text/")) return .{ .text = "" };

    var encoding_storage: [64]u8 = undefined;
    const encoding = header(headers, "content-transfer-encoding", &encoding_storage) orelse "7bit";

    var decoded: usize = 0;

    if (std.ascii.eqlIgnoreCase(encoding, "base64")) {

        decoded = decode_base64(body, out);

    } else if (std.ascii.eqlIgnoreCase(encoding, "quoted-printable")) {

        decoded = decode_quoted(body, out, false);

    } else {

        decoded = copy_utf8(body, out);

    }

    return .{ .text = out[0..decoded], .html = html };

}

/// Prefer text/plain; fall back to the first text/html part so HTML-only mail still reads.
fn walk_multipart(body: []const u8, boundary: []const u8, out: []u8, depth: usize) Body {

    var marker_storage: [136]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_storage, "--{s}", .{boundary}) catch return .{ .text = "" };

    var fallback: Body = .{ .text = "" };
    var fallback_used = false;

    var cursor = std.mem.indexOf(u8, body, marker) orelse return .{ .text = "" };

    while (cursor < body.len) {

        const start = next_line(body, cursor);
        const end = if (std.mem.indexOfPos(u8, body, start, marker)) |at| at else body.len;

        if (start >= end) break;

        const part = split(body[start..end]);
        const found = walk(part.headers, part.body, out, depth + 1);

        if (found.text.len > 0) {

            if (!found.html) return found;

            if (!fallback_used) {

                fallback = found;
                fallback_used = true;

            }

        }

        if (end == body.len) break;

        cursor = end + marker.len;

    }

    return fallback;

}

/// Pull `name=value` out of a header value, quoted or bare.
pub fn parameter(value: []const u8, name: []const u8, out: []u8) ?[]const u8 {

    var index: usize = 0;

    while (std.mem.indexOfScalarPos(u8, value, index, ';')) |semi| {

        var rest = std.mem.trimLeft(u8, value[semi + 1 ..], " \t");
        const equals = std.mem.indexOfScalar(u8, rest, '=') orelse {

            index = semi + 1;
            continue;

        };

        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, rest[0..equals], " \t"), name)) {

            index = semi + 1;
            continue;

        }

        rest = std.mem.trim(u8, rest[equals + 1 ..], " \t");

        const text = if (rest.len >= 2 and rest[0] == '"')
            rest[1 .. (std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse rest.len)]
        else if (std.mem.indexOfAny(u8, rest, "; \t")) |stop|
            rest[0..stop]
        else
            rest;

        const length = @min(text.len, out.len);

        @memcpy(out[0..length], text[0..length]);

        return out[0..length];

    }

    return null;

}

/// When `at` opens a <script>/<style>, the offset of its closing '>' so the caller can resume there.
fn skip_block(input: []const u8, at: usize, tag: []const u8) ?usize {

    var open_storage: [12]u8 = undefined;
    var close_storage: [12]u8 = undefined;

    const open = std.fmt.bufPrint(&open_storage, "<{s}", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_storage, "</{s}", .{tag}) catch return null;

    if (!std.ascii.startsWithIgnoreCase(input[at..], open)) return null;

    const closing = find_ignore_case(input, at, close) orelse return input.len;

    return std.mem.indexOfScalarPos(u8, input, closing, '>') orelse input.len;

}

fn find_ignore_case(haystack: []const u8, start: usize, needle: []const u8) ?usize {

    var index = start;

    while (index + needle.len <= haystack.len) : (index += 1) {

        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return index;

    }

    return null;

}

/// Crude tag stripper so HTML-only mail is at least readable.
pub fn strip_html(input: []const u8, out: []u8) []const u8 {

    var written: usize = 0;
    var index: usize = 0;
    var depth: usize = 0;
    var space = true;

    while (index < input.len and written < out.len) : (index += 1) {

        const byte = input[index];

        if (byte == '<') {

            // Drop script and style bodies wholesale, not just their tags.
            if (skip_block(input, index, "script") orelse skip_block(input, index, "style")) |resume_at| {

                index = resume_at;
                continue;

            }

            depth += 1;
            continue;

        }

        if (byte == '>') {

            if (depth > 0) depth -= 1;

            continue;

        }

        if (depth > 0) continue;

        const blank = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';

        if (blank) {

            if (space) continue;

            out[written] = if (byte == '\n') '\n' else ' ';

            written += 1;
            space = true;

            continue;

        }

        out[written] = byte;

        written += 1;
        space = false;

    }

    return std.mem.trim(u8, out[0..written], " \n");

}

const testing = std.testing;

test "folded headers rejoin into one value" {

    const headers = "From: a@b.c\r\nSubject: hello\r\n there\r\nDate: Mon, 1 Jan 2024\r\n";

    var out: [128]u8 = undefined;

    try testing.expectEqualStrings("hello there", header(headers, "subject", &out).?);
    try testing.expectEqualStrings("a@b.c", header(headers, "FROM", &out).?);
    try testing.expect(header(headers, "to", &out) == null);

}

test "encoded words decode from base64 and quoted-printable" {

    var out: [128]u8 = undefined;

    try testing.expectEqualStrings("Hello", decode_words("=?UTF-8?B?SGVsbG8=?=", &out));
    try testing.expectEqualStrings("a b", decode_words("=?UTF-8?Q?a_b?=", &out));
    try testing.expectEqualStrings("Re: caf\u{e9}", decode_words("Re: =?ISO-8859-1?Q?caf=E9?=", &out));
    try testing.expectEqualStrings("plain text", decode_words("plain text", &out));

}

test "quoted-printable joins soft line breaks" {

    var out: [64]u8 = undefined;
    const length = decode_quoted("one=\r\ntwo=20three", &out, false);

    try testing.expectEqualStrings("onetwo three", out[0..length]);

}

test "multipart alternative prefers the plain text part" {

    const message =
        "Content-Type: multipart/alternative; boundary=\"xyz\"\r\n\r\n" ++
        "--xyz\r\n" ++
        "Content-Type: text/html\r\n\r\n" ++
        "<p>markup</p>\r\n" ++
        "--xyz\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "the real text\r\n" ++
        "--xyz--\r\n";

    var out: [256]u8 = undefined;
    const body = extract_body(message, &out);

    try testing.expect(!body.html);
    try testing.expect(std.mem.indexOf(u8, body.text, "the real text") != null);

}

test "html-only mail falls back and strips tags" {

    const message =
        "Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n" ++
        "--b\r\n" ++
        "Content-Type: text/html\r\n\r\n" ++
        "<div>hello <b>world</b></div>\r\n" ++
        "--b--\r\n";

    var out: [256]u8 = undefined;
    const body = extract_body(message, &out);

    try testing.expect(body.html);

    var stripped: [256]u8 = undefined;

    try testing.expectEqualStrings("hello world", strip_html(body.text, &stripped));

}

test "html stripping drops script and style bodies" {

    const markup = "<style>p{color:red}</style><p>keep</p><script>var x = 1 < 2;</script> this";

    var out: [128]u8 = undefined;

    try testing.expectEqualStrings("keep this", strip_html(markup, &out));

}

test "single part message decodes base64" {

    const message = "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVsbG8gbWFpbA==";

    var out: [64]u8 = undefined;

    try testing.expectEqualStrings("Hello mail", extract_body(message, &out).text);

}

test "content type parameters read quoted and bare forms" {

    var out: [64]u8 = undefined;

    try testing.expectEqualStrings("abc", parameter("multipart/mixed; boundary=\"abc\"", "boundary", &out).?);
    try testing.expectEqualStrings("abc", parameter("multipart/mixed; boundary=abc", "boundary", &out).?);
    try testing.expectEqualStrings("utf-8", parameter("text/plain; charset=utf-8; format=flowed", "charset", &out).?);

}
