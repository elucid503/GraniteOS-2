// Shoutcast/Icecast streaming client: one long-lived HTTP response that never ends.
//
// Unlike http.request, nothing here buffers the whole body. `read` hands back audio bytes and
// quietly strips the metadata blocks the server interleaves every `icy-metaint` bytes.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const mem = @import("../mem/mem.zig");
const http = @import("http.zig");
const url_mod = @import("url.zig");

const Handle = cap.Handle;

pub const Error = error{

    Invalid,
    BadUrl,
    RequestTooLong,
    HeadTooLarge,
    BadStatusLine,
    BadStatus,
    TooManyRedirects,
    Closed,

} || http.Error;

pub const max_title = 192;
pub const max_name = 96;
pub const max_url = 256;

const buffer_size = 8192;
const max_metadata = 16 * 255;
const max_redirects = 4;

pub const Codec = enum {

    mpeg,
    aac,
    ogg,
    unknown,

    pub fn label(self: Codec) []const u8 {

        return switch (self) {

            .mpeg => "MP3",
            .aac => "AAC",
            .ogg => "Ogg",
            .unknown => "unknown",

        };

    }

};

/// Immovable once opened: it owns a TLS session that stores interior pointers.
pub const Stream = struct {

    connection: http.Connection = undefined,
    live: bool = false,

    buffer: [buffer_size]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    metaint: usize = 0,
    until_meta: usize = 0,
    state: enum { audio, meta_length, meta_body } = .audio,

    meta: [max_metadata]u8 = undefined,
    meta_len: usize = 0,
    meta_want: usize = 0,

    name_storage: [max_name]u8 = undefined,
    name_len: usize = 0,

    title_storage: [max_title]u8 = undefined,
    title_len: usize = 0,
    title_serial: u32 = 0,

    codec: Codec = .unknown,
    bitrate: u32 = 0,

    pub fn open(out: *Stream, authority: Handle, heap: *mem.Heap, location: []const u8) Error!void {

        out.* = .{};

        var target: [max_url]u8 = undefined;
        var target_len: usize = @min(location.len, target.len);

        @memcpy(target[0..target_len], location[0..target_len]);

        var hops: usize = 0;

        while (hops <= max_redirects) : (hops += 1) {

            const redirect = try out.attempt(authority, heap, target[0..target_len], &target);

            if (redirect == 0) return;

            target_len = redirect;

        }

        return error.TooManyRedirects;

    }

    /// Connect and read the response head. Returns 0 on success, or the length of a redirect
    /// target written into `next`.
    fn attempt(self: *Stream, authority: Handle, heap: *mem.Heap, location: []const u8, next: *[max_url]u8) Error!usize {

        const parsed = url_mod.parse(location) orelse return error.BadUrl;

        try http.Connection.connect_host(
            &self.connection,
            authority,
            heap,
            parsed.host,
            parsed.port,
            url_mod.is_tls(parsed.scheme),
        );

        self.live = true;
        errdefer self.shutdown();

        var request: [640]u8 = undefined;
        const text = std.fmt.bufPrint(
            &request,
            "GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: GraniteOS-Radio/1.0\r\nIcy-MetaData: 1\r\nAccept: */*\r\nConnection: close\r\n\r\n",
            .{ parsed.path, parsed.host },
        ) catch return error.RequestTooLong;

        try self.connection.send_all(text);

        const head_end = try self.read_head();
        const head = self.buffer[0..head_end];
        const status = try parse_status(head);

        if (status >= 300 and status < 400) {

            const target = header_value(head, "location") orelse return error.BadStatus;
            const length = @min(target.len, next.len);

            var copy: [max_url]u8 = undefined;

            @memcpy(copy[0..length], target[0..length]);

            self.shutdown();
            self.reset_framing();

            @memcpy(next[0..length], copy[0..length]);

            return length;

        }

        // Icecast answers "ICY 200 OK"; both it and plain HTTP 200 mean the stream follows.
        if (status != 200) return error.BadStatus;

        self.apply_head(head);

        // Everything after the blank line is already stream body.
        self.head = head_end;

        return 0;

    }

    fn read_head(self: *Stream) Error!usize {

        self.head = 0;
        self.tail = 0;

        // The terminator check has to come after the read that filled the buffer: a live stream
        // hands over the head and a few kilobytes of audio in the very first recv.
        while (true) {

            if (std.mem.indexOf(u8, self.buffer[0..self.tail], "\r\n\r\n")) |at| return at + 4;

            if (self.tail == self.buffer.len) return error.HeadTooLarge;

            const count = try self.connection.recv(self.buffer[self.tail..]);

            if (count == 0) return error.Closed;

            self.tail += count;

        }

    }

    fn apply_head(self: *Stream, head: []const u8) void {

        if (header_value(head, "icy-metaint")) |text| {

            self.metaint = std.fmt.parseInt(usize, text, 10) catch 0;

        }

        self.until_meta = self.metaint;

        if (header_value(head, "icy-br")) |text| {

            self.bitrate = std.fmt.parseInt(u32, text, 10) catch 0;

        }

        if (header_value(head, "icy-name")) |text| {

            self.name_len = @min(text.len, self.name_storage.len);

            @memcpy(self.name_storage[0..self.name_len], text[0..self.name_len]);

        }

        const content_type = header_value(head, "content-type") orelse "";

        self.codec = if (contains_ignore_case(content_type, "mpeg") or contains_ignore_case(content_type, "mp3"))
            .mpeg
        else if (contains_ignore_case(content_type, "aac"))
            .aac
        else if (contains_ignore_case(content_type, "ogg") or contains_ignore_case(content_type, "opus"))
            .ogg
        else
            .unknown;

    }

    fn reset_framing(self: *Stream) void {

        self.head = 0;
        self.tail = 0;
        self.metaint = 0;
        self.until_meta = 0;
        self.state = .audio;
        self.meta_len = 0;
        self.meta_want = 0;

    }

    /// Fill `out` with audio bytes, stripping any interleaved metadata. Returns 0 at end of stream.
    pub fn read(self: *Stream, out: []u8) Error!usize {

        if (!self.live) return error.Closed;

        var written: usize = 0;

        while (written < out.len) {

            if (self.pending() == 0) {

                // Only block when we have nothing to hand back yet.
                if (written > 0) break;

                if (!try self.pull()) return 0;

                continue;

            }

            switch (self.state) {

                .audio => {

                    var take = @min(self.pending(), out.len - written);

                    if (self.metaint != 0) take = @min(take, self.until_meta);

                    @memcpy(out[written..][0..take], self.buffer[self.head..][0..take]);

                    self.head += take;
                    written += take;

                    if (self.metaint != 0) {

                        self.until_meta -= take;

                        if (self.until_meta == 0) self.state = .meta_length;

                    }

                },

                .meta_length => {

                    self.meta_want = @as(usize, self.buffer[self.head]) * 16;
                    self.head += 1;
                    self.meta_len = 0;

                    if (self.meta_want == 0) {

                        self.until_meta = self.metaint;
                        self.state = .audio;

                    } else {

                        self.state = .meta_body;

                    }

                },

                .meta_body => {

                    const take = @min(self.pending(), self.meta_want - self.meta_len);

                    @memcpy(self.meta[self.meta_len..][0..take], self.buffer[self.head..][0..take]);

                    self.head += take;
                    self.meta_len += take;

                    if (self.meta_len == self.meta_want) {

                        self.apply_metadata(self.meta[0..self.meta_len]);

                        self.until_meta = self.metaint;
                        self.state = .audio;

                    }

                },

            }

        }

        return written;

    }

    fn pending(self: *const Stream) usize {

        return self.tail - self.head;

    }

    fn pull(self: *Stream) Error!bool {

        self.head = 0;
        self.tail = 0;

        const count = try self.connection.recv(&self.buffer);

        if (count == 0) return false;

        self.tail = count;

        return true;

    }

    fn apply_metadata(self: *Stream, block: []const u8) void {

        const key = "StreamTitle='";
        const at = std.mem.indexOf(u8, block, key) orelse return;
        const rest = block[at + key.len ..];
        const end = std.mem.indexOf(u8, rest, "';") orelse rest.len;
        const text = std.mem.trim(u8, rest[0..end], " ");
        const length = @min(text.len, self.title_storage.len);

        if (std.mem.eql(u8, self.title_storage[0..self.title_len], text[0..length])) return;

        @memcpy(self.title_storage[0..length], text[0..length]);

        self.title_len = length;
        self.title_serial +%= 1;

    }

    pub fn title(self: *const Stream) []const u8 {

        return self.title_storage[0..self.title_len];

    }

    pub fn name(self: *const Stream) []const u8 {

        return self.name_storage[0..self.name_len];

    }

    fn shutdown(self: *Stream) void {

        if (!self.live) return;

        self.connection.close();
        self.live = false;

    }

    pub fn close(self: *Stream) void {

        self.shutdown();

    }

};

fn parse_status(head: []const u8) Error!u16 {

    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadStatusLine;
    const line = head[0..line_end];
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadStatusLine;
    const rest = std.mem.trimLeft(u8, line[space + 1 ..], " ");

    var end: usize = 0;

    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}

    if (end == 0) return error.BadStatusLine;

    return std.fmt.parseInt(u16, rest[0..end], 10) catch error.BadStatusLine;

}

fn header_value(head: []const u8, field: []const u8) ?[]const u8 {

    var lines = std.mem.splitSequence(u8, head, "\r\n");

    _ = lines.next();

    while (lines.next()) |line| {

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), field)) continue;

        return std.mem.trim(u8, line[colon + 1 ..], " \t");

    }

    return null;

}

fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {

    if (needle.len > haystack.len) return false;

    var index: usize = 0;

    while (index + needle.len <= haystack.len) : (index += 1) {

        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;

    }

    return false;

}

const testing = std.testing;

test "parses icy and http status lines" {

    try testing.expectEqual(@as(u16, 200), try parse_status("ICY 200 OK\r\n"));
    try testing.expectEqual(@as(u16, 200), try parse_status("HTTP/1.0 200 OK\r\n"));
    try testing.expectEqual(@as(u16, 302), try parse_status("HTTP/1.1 302 Found\r\n"));
    try testing.expectError(error.BadStatusLine, parse_status("garbage\r\n"));

}

test "reads icy headers case-insensitively" {

    const head = "ICY 200 OK\r\nicy-name:Radio Granite\r\nIcy-MetaInt: 16000\r\nContent-Type: audio/mpeg\r\n\r\n";

    try testing.expectEqualStrings("Radio Granite", header_value(head, "icy-name").?);
    try testing.expectEqualStrings("16000", header_value(head, "icy-metaint").?);
    try testing.expect(header_value(head, "icy-url") == null);

}

test "strips interleaved metadata from the audio stream" {

    var stream = Stream{};

    stream.metaint = 4;
    stream.until_meta = 4;
    stream.live = true;

    // Four audio bytes, a 1x16-byte metadata block, then four more audio bytes.
    const block = "StreamTitle='Hi';" ++ "\x00" ** 15;
    const payload = "AAAA" ++ [_]u8{1} ++ block[0..16].* ++ "BBBB";

    @memcpy(stream.buffer[0..payload.len], payload);
    stream.tail = payload.len;

    var out: [16]u8 = undefined;
    const count = try stream.read(&out);

    try testing.expectEqualStrings("AAAABBBB", out[0..count]);
    try testing.expectEqualStrings("Hi", stream.title());
    try testing.expectEqual(@as(u32, 1), stream.title_serial);

}
