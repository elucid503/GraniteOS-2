// Lightweight cross-app notification inbox. Producers post a compact record; the taskbar consumes
// it into its live notification center, so no application needs a privileged desktop capability.

const cap = @import("../cap/cap.zig");
const fs = @import("../fs/fs.zig");
const proto = @import("../ipc/proto.zig");

pub const title_capacity = 32;
pub const body_capacity = 96;
const inbox_path = "/root/user/notification.inbox";

pub const Entry = struct {

    title: [title_capacity]u8 = [_]u8{0} ** title_capacity,
    title_len: usize = 0,
    body: [body_capacity]u8 = [_]u8{0} ** body_capacity,
    body_len: usize = 0,

};

/// Replace the pending inbox record. Notifications are rare and the taskbar consumes promptly;
/// keeping a single handoff record avoids granting every GUI app a long-lived desktop endpoint.
pub fn post(title: []const u8, body: []const u8) void {

    var client = fs.Client.connect(cap.memory) catch return;
    defer client.close();

    const file = client.open_path(inbox_path, proto.filesystem.open_create | proto.filesystem.open_truncate) catch return;
    defer client.close_file(file) catch {};

    var encoded: [title_capacity + body_capacity + 1]u8 = undefined;
    const title_len = @min(title.len, title_capacity);
    const body_len = @min(body.len, body_capacity);

    @memcpy(encoded[0..title_len], title[0..title_len]);
    encoded[title_len] = '\n';
    @memcpy(encoded[title_len + 1 .. title_len + 1 + body_len], body[0..body_len]);

    _ = client.write(file, 0, encoded[0 .. title_len + 1 + body_len]) catch {};

}

/// Consume one pending record. The taskbar retains the user-visible history after this handoff.
pub fn take() ?Entry {

    var client = fs.Client.connect(cap.memory) catch return null;
    defer client.close();

    const file = client.open_path(inbox_path, 0) catch return null;
    defer client.close_file(file) catch {};

    var encoded: [title_capacity + body_capacity + 1]u8 = undefined;
    const length = client.read(file, 0, &encoded) catch return null;

    _ = client.delete(inbox_path) catch {};

    if (length == 0) return null;

    var entry = Entry{};
    var split: usize = 0;

    while (split < length and encoded[split] != '\n') : (split += 1) {}

    entry.title_len = @min(split, entry.title.len);
    @memcpy(entry.title[0..entry.title_len], encoded[0..entry.title_len]);

    const body_start = @min(length, split + 1);
    entry.body_len = @min(length - body_start, entry.body.len);
    @memcpy(entry.body[0..entry.body_len], encoded[body_start .. body_start + entry.body_len]);

    return entry;

}
