// The system clipboard: a most-recent-first history staged in one file so every process shares it.

const std = @import("std");

const cap = @import("cap/cap.zig");
const fs = @import("fs/fs.zig");
const layout = @import("fs/layout.zig");
const proto = @import("ipc/proto.zig");

pub const path = "/temp/clipboard";

pub const max_entry = 2048;
pub const max_entries = 8;

const magic = "GCB1";

/// Worst-case file size: the magic plus a length-prefixed record per entry.
pub const file_bytes = magic.len + max_entries * (4 + max_entry);

pub const History = struct {

    bytes: [max_entries * max_entry]u8 = undefined,
    lengths: [max_entries]u16 = [_]u16{0} ** max_entries,
    count: usize = 0,

    pub fn entry(self: *const History, index: usize) []const u8 {

        if (index >= self.count) return "";

        return self.bytes[index * max_entry ..][0..self.lengths[index]];

    }

    pub fn set(self: *History, index: usize, text: []const u8) void {

        if (index >= self.count) return;

        const length = @min(text.len, max_entry);

        @memcpy(self.bytes[index * max_entry ..][0..length], text[0..length]);
        self.lengths[index] = @intCast(length);

    }

    pub fn remove(self: *History, index: usize) void {

        if (index >= self.count) return;

        var slot = index;

        while (slot + 1 < self.count) : (slot += 1) {

            const length = self.lengths[slot + 1];

            @memcpy(self.bytes[slot * max_entry ..][0..length], self.bytes[(slot + 1) * max_entry ..][0..length]);
            self.lengths[slot] = length;

        }

        self.count -= 1;

    }

    pub fn clear(self: *History) void {

        self.count = 0;

    }

    /// Put `text` at the front, folding an existing identical entry into the move.
    pub fn prepend(self: *History, text: []const u8) void {

        if (text.len == 0) return;

        const length = @min(text.len, max_entry);
        const wanted = text[0..length];

        for (0..self.count) |index| {

            if (std.mem.eql(u8, self.entry(index), wanted)) {

                self.remove(index);
                break;

            }

        }

        if (self.count < max_entries) self.count += 1;

        var slot = self.count - 1;

        while (slot > 0) : (slot -= 1) {

            const moved = self.lengths[slot - 1];

            @memcpy(self.bytes[slot * max_entry ..][0..moved], self.bytes[(slot - 1) * max_entry ..][0..moved]);
            self.lengths[slot] = moved;

        }

        @memcpy(self.bytes[0..length], wanted);
        self.lengths[0] = @intCast(length);

    }

    fn encode(self: *const History, out: []u8) []const u8 {

        @memcpy(out[0..magic.len], magic);

        var length: usize = magic.len;

        for (0..self.count) |index| {

            const text = self.entry(index);

            std.mem.writeInt(u32, out[length..][0..4], @intCast(text.len), .little);
            length += 4;

            @memcpy(out[length..][0..text.len], text);
            length += text.len;

        }

        return out[0..length];

    }

    fn decode(self: *History, text: []const u8) void {

        self.count = 0;

        if (text.len < magic.len or !std.mem.eql(u8, text[0..magic.len], magic)) return;

        var offset: usize = magic.len;

        while (offset + 4 <= text.len and self.count < max_entries) {

            const length = std.mem.readInt(u32, text[offset..][0..4], .little);
            offset += 4;

            if (length > max_entry or offset + length > text.len) return;

            const slot = self.count;

            @memcpy(self.bytes[slot * max_entry ..][0..length], text[offset..][0..length]);
            self.lengths[slot] = @intCast(length);
            self.count += 1;

            offset += length;

        }

    }

};

pub fn load(history: *History) void {

    var client = fs.Client.connect(cap.memory) catch {

        history.count = 0;
        return;

    };
    defer client.close();

    load_with(&client, history);

}

pub fn load_with(client: *fs.Client, history: *History) void {

    history.count = 0;

    const file = client.open_path(path, 0) catch return;
    defer client.close_file(file) catch {};

    var text: [file_bytes]u8 = undefined;
    var length: usize = 0;

    while (length < text.len) {

        const read = client.read(file, length, text[length..]) catch break;

        if (read == 0) break;

        length += read;

    }

    history.decode(text[0..length]);

}

pub fn store(history: *const History) void {

    var client = fs.Client.connect(cap.memory) catch return;
    defer client.close();

    store_with(&client, history);

}

pub fn store_with(client: *fs.Client, history: *const History) void {

    client.mkdir(layout.temp) catch {};

    // Truncate rather than delete: a shrinking history must not leave a stale tail behind.
    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = client.open_path(path, flags) catch return;
    defer client.close_file(file) catch {};

    var text: [file_bytes]u8 = undefined;
    const encoded = history.encode(&text);

    var offset: usize = 0;

    while (offset < encoded.len) {

        const written = client.write(file, offset, encoded[offset..]) catch break;

        if (written == 0) break;

        offset += written;

    }

}

/// Put `text` at the front of the history (the Ctrl+C / Ctrl+X path).
pub fn copy(text: []const u8) void {

    if (text.len == 0) return;

    // One session for both halves: a fresh filesystem client maps a 64 KiB buffer, and a GUI app
    // copying repeatedly should not pay for that twice per keystroke.
    var client = fs.Client.connect(cap.memory) catch return;
    defer client.close();

    var history: History = .{};

    load_with(&client, &history);
    history.prepend(text);
    store_with(&client, &history);

}

/// The most recent entry, or null when the clipboard is empty (the Ctrl+V path).
pub fn paste(out: []u8) ?[]const u8 {

    var history: History = .{};

    load(&history);

    if (history.count == 0) return null;

    const text = history.entry(0);
    const length = @min(text.len, out.len);

    if (length == 0) return null;

    @memcpy(out[0..length], text[0..length]);

    return out[0..length];

}

const testing = std.testing;

test "prepend keeps the newest entry first and drops the oldest" {

    var history: History = .{};

    for (0..max_entries + 2) |index| {

        var name: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "item{d}", .{index}) catch unreachable;

        history.prepend(text);

    }

    try testing.expectEqual(max_entries, history.count);
    try testing.expectEqualStrings("item9", history.entry(0));
    try testing.expectEqualStrings("item8", history.entry(1));

}

test "copying an entry that is already present promotes it" {

    var history: History = .{};

    history.prepend("one");
    history.prepend("two");
    history.prepend("three");
    history.prepend("one");

    try testing.expectEqual(@as(usize, 3), history.count);
    try testing.expectEqualStrings("one", history.entry(0));
    try testing.expectEqualStrings("three", history.entry(1));
    try testing.expectEqualStrings("two", history.entry(2));

}

test "history survives an encode and decode round-trip" {

    var history: History = .{};

    history.prepend("alpha");
    history.prepend("line one\nline two");

    var text: [file_bytes]u8 = undefined;
    const encoded = history.encode(&text);

    var restored: History = .{};
    restored.decode(encoded);

    try testing.expectEqual(@as(usize, 2), restored.count);
    try testing.expectEqualStrings("line one\nline two", restored.entry(0));
    try testing.expectEqualStrings("alpha", restored.entry(1));

}

test "removing and editing entries keeps the rest intact" {

    var history: History = .{};

    history.prepend("c");
    history.prepend("b");
    history.prepend("a");

    history.set(1, "edited");
    history.remove(0);

    try testing.expectEqual(@as(usize, 2), history.count);
    try testing.expectEqualStrings("edited", history.entry(0));
    try testing.expectEqualStrings("c", history.entry(1));

    history.clear();

    try testing.expectEqual(@as(usize, 0), history.count);
    try testing.expectEqualStrings("", history.entry(0));

}

test "a truncated or foreign file decodes as an empty history" {

    var history: History = .{};

    history.decode("");
    try testing.expectEqual(@as(usize, 0), history.count);

    history.decode("NOPE" ++ [_]u8{ 1, 0, 0, 0, 'x' });
    try testing.expectEqual(@as(usize, 0), history.count);

    history.decode(magic ++ [_]u8{ 8, 0, 0, 0, 'x' });
    try testing.expectEqual(@as(usize, 0), history.count);

}
