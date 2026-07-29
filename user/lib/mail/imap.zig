// Read-only IMAP4 client for inbox fetch; Gmail uses TLS:993 with AUTH=PLAIN + SASL-IR.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const mem = @import("../mem/mem.zig");
const http = @import("../net/http.zig");

const Handle = cap.Handle;

pub const Error = error{

    Protocol,
    Rejected,
    AuthFailed,
    Closed,
    TooLong,

} || http.Error;

pub const max_from = 96;
pub const max_subject = 140;
pub const max_date = 32;

const buffer_size = 4096;
const line_size = 2048;

// A generous ceiling on untagged lines per command; only a desynced stream ever reaches it.
const max_response_lines = 4096;

// Servers that go quiet mid-command should surface an error, not wedge the caller's thread.
const read_timeout_ms = 20 * 1000;

pub const Envelope = struct {

    seq: u32 = 0,

    from: [max_from]u8 = undefined,
    from_len: usize = 0,

    subject: [max_subject]u8 = undefined,
    subject_len: usize = 0,

    date: [max_date]u8 = undefined,
    date_len: usize = 0,

    seen: bool = false,

    pub fn sender(self: *const Envelope) []const u8 {

        return self.from[0..self.from_len];

    }

    pub fn title(self: *const Envelope) []const u8 {

        return self.subject[0..self.subject_len];

    }

    pub fn when(self: *const Envelope) []const u8 {

        return self.date[0..self.date_len];

    }

};

/// Immovable once connected: it owns a TLS session with interior pointers.
pub const Client = struct {

    connection: http.Connection = undefined,
    live: bool = false,

    buffer: [buffer_size]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    tag: u32 = 0,
    plain_auth: bool = false,
    exists: u32 = 0,

    /// `secure` picks IMAPS (993) over plain IMAP (143). The greeting is consumed here.
    pub fn connect(self: *Client, authority: Handle, heap: *mem.Heap, host: []const u8, port: u16, secure: bool) Error!void {

        self.* = .{};

        try http.Connection.connect_host(&self.connection, authority, heap, host, port, secure);

        self.live = true;
        errdefer self.close();

        // Set only after the handshake, which has no deadline of its own.
        self.connection.set_read_timeout(read_timeout_ms);

        var line: [line_size]u8 = undefined;
        const greeting = try self.read_line(&line);

        if (!std.mem.startsWith(u8, greeting, "* OK")) return error.Rejected;

        // The greeting sometimes carries the capability list; otherwise ask.
        if (std.mem.indexOf(u8, greeting, "AUTH=PLAIN") != null) {

            self.plain_auth = true;
            return;

        }

        try self.capability();

    }

    fn capability(self: *Client) Error!void {

        var line: [line_size]u8 = undefined;
        var budget: usize = max_response_lines;

        const tag = try self.send("CAPABILITY", .{});

        while (try self.next_response(&line, tag, &budget)) |response| {

            if (std.mem.indexOf(u8, response, "AUTH=PLAIN") != null) self.plain_auth = true;

        }

    }

    /// Authenticate. Credentials are used here and never retained.
    pub fn login(self: *Client, user: []const u8, password: []const u8) Error!void {

        var line: [line_size]u8 = undefined;

        const tag = if (self.plain_auth) blk: {

            // SASL PLAIN is authzid NUL authcid NUL password, base64'd as an initial response.
            var raw: [512]u8 = undefined;

            if (user.len + password.len + 2 > raw.len) return error.TooLong;

            raw[0] = 0;

            @memcpy(raw[1..][0..user.len], user);

            raw[1 + user.len] = 0;

            @memcpy(raw[2 + user.len ..][0..password.len], password);

            const length = user.len + password.len + 2;

            var encoded: [700]u8 = undefined;
            const text = std.base64.standard.Encoder.encode(&encoded, raw[0..length]);

            break :blk try self.send("AUTHENTICATE PLAIN {s}", .{text});

        } else blk: {

            var user_quoted: [128]u8 = undefined;
            var secret_quoted: [128]u8 = undefined;

            break :blk try self.send("LOGIN {s} {s}", .{ quote(user, &user_quoted), quote(password, &secret_quoted) });

        };

        var budget: usize = max_response_lines;

        while (true) {

            if (budget == 0) return error.Protocol;

            budget -= 1;

            const response = try self.read_line(&line);

            // A "+" here means the server wants the payload as a continuation; we always send SASL-IR.
            if (response.len > 0 and response[0] == '+') return error.AuthFailed;

            if (self.completion_status(response, tag)) |ok| {

                if (!ok) return error.AuthFailed;

                return;

            }

        }

    }

    /// Select a mailbox read-only and return the message count.
    pub fn examine(self: *Client, mailbox: []const u8) Error!u32 {

        var line: [line_size]u8 = undefined;
        var name: [128]u8 = undefined;
        const tag = try self.send("EXAMINE {s}", .{quote(mailbox, &name)});

        self.exists = 0;

        var budget: usize = max_response_lines;

        while (try self.next_response(&line, tag, &budget)) |response| {

            // "* 1234 EXISTS"
            if (std.mem.startsWith(u8, response, "* ") and std.mem.endsWith(u8, response, " EXISTS")) {

                const digits = response[2 .. response.len - " EXISTS".len];

                self.exists = std.fmt.parseInt(u32, digits, 10) catch 0;

            }

        }

        return self.exists;

    }

    /// Fetch envelopes for `first`..`last` into `out` (newest first); returns count filled.
    pub fn fetch_envelopes(self: *Client, first: u32, last: u32, out: []Envelope) Error!usize {

        if (first > last or out.len == 0) return 0;

        var line: [line_size]u8 = undefined;
        var headers: [2048]u8 = undefined;

        // Start clean so a short or gappy reply cannot leave a previous fetch's rows behind.
        for (out) |*slot| slot.* = .{};

        const tag = try self.send("FETCH {d}:{d} (FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])", .{ first, last });

        var count: usize = 0;
        var budget: usize = max_response_lines;

        // Keep the row alive until the next response; FLAGS can trail the literal.
        var pending: ?*Envelope = null;

        while (try self.next_response(&line, tag, &budget)) |response| {

            const literal = literal_length(response) orelse {

                if (pending) |slot| {

                    if (std.mem.indexOf(u8, response, "\\Seen") != null) slot.seen = true;

                    pending = null;

                }

                continue;

            };

            const wanted = @min(literal, headers.len);

            try self.read_exact(headers[0..wanted]);
            try self.discard(literal - wanted);

            const sequence = untagged_number(response) orelse continue;

            // Newest message first: sequence numbers ascend, so fill from the back.
            const offset = last - @min(sequence, last);

            if (offset >= out.len) continue;

            const slot = &out[offset];

            slot.* = .{ .seq = sequence, .seen = std.mem.indexOf(u8, response, "\\Seen") != null };

            fill_field(headers[0..wanted], "from", &slot.from, &slot.from_len);
            fill_field(headers[0..wanted], "subject", &slot.subject, &slot.subject_len);
            fill_field(headers[0..wanted], "date", &slot.date, &slot.date_len);

            pending = slot;
            count = @max(count, offset + 1);

        }

        return count;

    }

    /// Fetch up to `out.len` bytes of one message, headers included. Returns the length written.
    pub fn fetch_message(self: *Client, sequence: u32, out: []u8) Error!usize {

        var line: [line_size]u8 = undefined;
        const tag = try self.send("FETCH {d} (BODY.PEEK[]<0.{d}>)", .{ sequence, out.len });

        var written: usize = 0;
        var budget: usize = max_response_lines;

        while (try self.next_response(&line, tag, &budget)) |response| {

            const literal = literal_length(response) orelse continue;
            const wanted = @min(literal, out.len);

            try self.read_exact(out[0..wanted]);
            try self.discard(literal - wanted);

            written = wanted;

        }

        return written;

    }

    pub fn logout(self: *Client) void {

        if (!self.live) return;

        _ = self.send("LOGOUT", .{}) catch {};

    }

    pub fn close(self: *Client) void {

        if (!self.live) return;

        self.connection.close();
        self.live = false;

    }

    // Command and response plumbing.

    fn send(self: *Client, comptime format: []const u8, args: anytype) Error!u32 {

        self.tag += 1;

        var command: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&command, "g{d} " ++ format ++ "\r\n", .{self.tag} ++ args) catch return error.TooLong;

        try self.connection.send_all(text);

        return self.tag;

    }

    /// Next untagged line for `tag`, or null at completion; `budget` caps lines per command.
    fn next_response(self: *Client, out: []u8, tag: u32, budget: *usize) Error!?[]const u8 {

        if (budget.* == 0) return error.Protocol;

        budget.* -= 1;

        const response = try self.read_line(out);

        if (try self.is_completion(response, tag)) return null;

        return response;

    }

    /// True when `response` is this command's tagged completion; errors on NO/BAD.
    fn is_completion(self: *Client, response: []const u8, tag: u32) Error!bool {

        const ok = self.completion_status(response, tag) orelse return false;

        if (!ok) return error.Rejected;

        return true;

    }

    fn completion_status(self: *Client, response: []const u8, tag: u32) ?bool {

        _ = self;

        var expected: [16]u8 = undefined;
        const prefix = std.fmt.bufPrint(&expected, "g{d} ", .{tag}) catch return null;

        if (!std.mem.startsWith(u8, response, prefix)) return null;

        return std.mem.startsWith(u8, response[prefix.len..], "OK");

    }

    /// One CRLF line; overflow is an error (truncation would desync the literal that follows).
    fn read_line(self: *Client, out: []u8) Error![]const u8 {

        var written: usize = 0;

        while (true) {

            if (self.head == self.tail) try self.fill();

            const byte = self.buffer[self.head];

            self.head += 1;

            if (byte == '\n') return std.mem.trimRight(u8, out[0..written], "\r");

            if (written >= out.len) return error.TooLong;

            out[written] = byte;
            written += 1;

        }

    }

    fn read_exact(self: *Client, out: []u8) Error!void {

        var written: usize = 0;

        while (written < out.len) {

            if (self.head == self.tail) try self.fill();

            const available = @min(self.tail - self.head, out.len - written);

            @memcpy(out[written..][0..available], self.buffer[self.head..][0..available]);

            self.head += available;
            written += available;

        }

    }

    fn discard(self: *Client, count: usize) Error!void {

        var remaining = count;

        while (remaining > 0) {

            if (self.head == self.tail) try self.fill();

            const step = @min(self.tail - self.head, remaining);

            self.head += step;
            remaining -= step;

        }

    }

    fn fill(self: *Client) Error!void {

        const count = try self.connection.recv_some(&self.buffer);

        if (count == 0) return error.Closed;

        self.head = 0;
        self.tail = count;

    }

};

/// Length of a trailing "{123}" literal announcement, if the line ends with one.
fn literal_length(line: []const u8) ?usize {

    if (line.len == 0 or line[line.len - 1] != '}') return null;

    const open = std.mem.lastIndexOfScalar(u8, line, '{') orelse return null;

    return std.fmt.parseInt(usize, line[open + 1 .. line.len - 1], 10) catch null;

}

/// The sequence number in an untagged response like "* 12 FETCH (...".
fn untagged_number(line: []const u8) ?u32 {

    if (!std.mem.startsWith(u8, line, "* ")) return null;

    const rest = line[2..];
    var end: usize = 0;

    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;

    if (end == 0) return null;

    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;

}

const mime = @import("mime.zig");

fn fill_field(headers: []const u8, name: []const u8, out: []u8, length: *usize) void {

    var raw: [512]u8 = undefined;
    var decoded: [512]u8 = undefined;

    const value = mime.header(headers, name, &raw) orelse {

        length.* = 0;
        return;

    };

    const text = mime.decode_words(value, &decoded);
    const pretty = if (std.ascii.eqlIgnoreCase(name, "from")) display_name(text) else text;

    length.* = @min(pretty.len, out.len);

    @memcpy(out[0..length.*], pretty[0..length.*]);

}

/// "Jane Doe <jane@x.com>" reads better as just "Jane Doe"; a bare address stays whole.
pub fn display_name(from: []const u8) []const u8 {

    const angle = std.mem.indexOfScalar(u8, from, '<') orelse return from;
    const name = std.mem.trim(u8, from[0..angle], " \t\"");

    if (name.len > 0) return name;

    const close = std.mem.indexOfScalarPos(u8, from, angle, '>') orelse from.len;

    return from[angle + 1 .. close];

}

/// An IMAP quoted string: wrapped in quotes, with backslash and quote escaped.
fn quote(text: []const u8, out: []u8) []const u8 {

    if (out.len < 2) return out[0..0];

    out[0] = '"';

    var written: usize = 1;

    for (text) |byte| {

        if (written + 3 > out.len) break;

        if (byte == '"' or byte == '\\') {

            out[written] = '\\';
            written += 1;

        }

        out[written] = byte;
        written += 1;

    }

    if (written < out.len) {

        out[written] = '"';
        written += 1;

    }

    return out[0..written];

}

const testing = std.testing;

test "literal announcements are recognised" {

    try testing.expectEqual(@as(?usize, 123), literal_length("* 1 FETCH (BODY[HEADER] {123}"));
    try testing.expectEqual(@as(?usize, null), literal_length("* 1 FETCH (FLAGS (\\Seen))"));
    try testing.expectEqual(@as(?usize, null), literal_length(""));

}

test "untagged sequence numbers parse" {

    try testing.expectEqual(@as(?u32, 12), untagged_number("* 12 FETCH (...)"));
    try testing.expectEqual(@as(?u32, 4), untagged_number("* 4 EXISTS"));
    try testing.expectEqual(@as(?u32, null), untagged_number("g3 OK done"));
    try testing.expectEqual(@as(?u32, null), untagged_number("* OK ready"));

}

test "sender display names collapse to the human part" {

    try testing.expectEqualStrings("Jane Doe", display_name("Jane Doe <jane@x.com>"));
    try testing.expectEqualStrings("Jane Doe", display_name("\"Jane Doe\" <jane@x.com>"));
    try testing.expectEqualStrings("jane@x.com", display_name("<jane@x.com>"));
    try testing.expectEqualStrings("jane@x.com", display_name("jane@x.com"));

}

test "envelope fields decode encoded words" {

    const headers = "From: =?UTF-8?B?SmFuZSBEb2U=?= <jane@x.com>\r\nSubject: =?UTF-8?Q?Re:_hi?=\r\nDate: Mon, 1 Jan 2024 10:00:00 +0000\r\n";

    var envelope = Envelope{};

    fill_field(headers, "from", &envelope.from, &envelope.from_len);
    fill_field(headers, "subject", &envelope.subject, &envelope.subject_len);
    fill_field(headers, "date", &envelope.date, &envelope.date_len);

    try testing.expectEqualStrings("Jane Doe", envelope.sender());
    try testing.expectEqualStrings("Re: hi", envelope.title());
    try testing.expectEqualStrings("Mon, 1 Jan 2024 10:00:00 +0000", envelope.when());

}
