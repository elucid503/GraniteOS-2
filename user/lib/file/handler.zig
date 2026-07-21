// File-type handlers: extension -> program associations, overridable from Settings.

const std = @import("std");

pub const Kind = enum(u8) {

    image = 0,
    audio = 1,
    text = 2,

};

pub const max_ext_len = 8;
pub const max_program_len = 32;
pub const max_handlers = 16;

pub const Slot = struct {

    ext: [max_ext_len]u8 = undefined,
    ext_len: u8 = 0,

    program: [max_program_len]u8 = undefined,
    program_len: u8 = 0,

    kind: Kind = .image,
    enabled: bool = true,

    pub fn extension(self: *const Slot) []const u8 {

        return self.ext[0..self.ext_len];

    }

    pub fn app(self: *const Slot) []const u8 {

        return self.program[0..self.program_len];

    }

};

const Builtin = struct {

    ext: []const u8,
    program: []const u8,
    kind: Kind,

};

const builtins = [_]Builtin{

    .{ .ext = "png", .program = "viewer", .kind = .image },
    .{ .ext = "wav", .program = "audio-gui", .kind = .audio },

};

/// Programs the Settings UI can cycle as open-with targets.
pub const program_choices = [_][]const u8{

    "viewer",
    "notepad",
    "audio-gui",

};

var slots: [max_handlers]Slot = undefined;
var slot_count: usize = 0;
var ready: bool = false;

pub fn ensure() void {

    if (ready) return;

    reset_defaults();

}

pub fn reset_defaults() void {

    slot_count = 0;

    for (builtins) |item| {

        _ = put(item.ext, item.program, item.kind, true);

    }

    ready = true;

}

pub fn count() usize {

    ensure();

    return slot_count;

}

pub fn at(index: usize) ?*const Slot {

    ensure();

    if (index >= slot_count) return null;

    return &slots[index];

}

pub fn at_mut(index: usize) ?*Slot {

    ensure();

    if (index >= slot_count) return null;

    return &slots[index];

}

/// Match a file name (not a full path) to an enabled handler.
pub fn match(name: []const u8) ?*const Slot {

    ensure();

    const ext = extension_of(name) orelse return null;

    for (slots[0..slot_count]) |*slot| {

        if (!slot.enabled) continue;
        if (eql_ascii_ignore_case(slot.extension(), ext)) return slot;

    }

    return null;

}

pub fn is_kind(name: []const u8, kind: Kind) bool {

    const slot = match(name) orelse return false;

    return slot.kind == kind;

}

pub fn set_program(ext: []const u8, program: []const u8) bool {

    ensure();

    const slot = find_mut(ext) orelse return false;

    if (program.len == 0) {

        slot.enabled = false;
        slot.program_len = 0;

        return true;

    }

    if (program.len > max_program_len) return false;

    @memcpy(slot.program[0..program.len], program);
    slot.program_len = @intCast(program.len);
    slot.enabled = true;

    return true;

}

pub fn set_enabled(ext: []const u8, enabled: bool) bool {

    ensure();

    const slot = find_mut(ext) orelse return false;

    slot.enabled = enabled;

    return true;

}

/// Cycle open-with: each choice program, then disabled.
pub fn cycle(index: usize) void {

    ensure();

    if (index >= slot_count) return;

    const slot = &slots[index];

    if (!slot.enabled or slot.program_len == 0) {

        const first = program_choices[0];

        @memcpy(slot.program[0..first.len], first);
        slot.program_len = @intCast(first.len);
        slot.enabled = true;

        return;

    }

    var choice: ?usize = null;

    for (program_choices, 0..) |name, i| {

        if (eql_ascii_ignore_case(slot.app(), name)) {

            choice = i;
            break;

        }

    }

    const next = if (choice) |i| i + 1 else 0;

    if (next >= program_choices.len) {

        slot.enabled = false;
        slot.program_len = 0;

        return;

    }

    const name = program_choices[next];

    @memcpy(slot.program[0..name.len], name);
    slot.program_len = @intCast(name.len);
    slot.enabled = true;

}

/// Apply a settings.cfg line of the form `open.<ext>=<program>` (empty program disables).
pub fn apply_config_line(line: []const u8) void {

    ensure();

    if (!std.mem.startsWith(u8, line, "open.")) return;

    const rest = line["open.".len..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return;
    const ext = trim_ascii(rest[0..eq]);
    const program = trim_ascii(rest[eq + 1 ..]);

    if (ext.len == 0) return;

    _ = set_program(ext, program);

}

/// Append `open.*=` lines for every slot into `dest`; returns the used prefix.
pub fn write_config(dest: []u8) usize {

    ensure();

    var cursor: usize = 0;

    for (slots[0..slot_count]) |slot| {

        const ext = slot.extension();
        const program = if (slot.enabled) slot.app() else "";
        const need = "open.".len + ext.len + 1 + program.len + 1;

        if (cursor + need > dest.len) break;

        @memcpy(dest[cursor..][0.."open.".len], "open.");
        cursor += "open.".len;
        @memcpy(dest[cursor..][0..ext.len], ext);
        cursor += ext.len;
        dest[cursor] = '=';
        cursor += 1;
        @memcpy(dest[cursor..][0..program.len], program);
        cursor += program.len;
        dest[cursor] = '\n';
        cursor += 1;

    }

    return cursor;

}

pub fn extension_of(name: []const u8) ?[]const u8 {

    if (name.len < 2) return null;

    var index = name.len;

    while (index > 0) {

        index -= 1;

        if (name[index] == '.') {

            if (index + 1 >= name.len) return null;

            return name[index + 1 ..];

        }

        if (name[index] == '/') return null;

    }

    return null;

}

fn put(ext: []const u8, program: []const u8, kind: Kind, enabled: bool) bool {

    if (ext.len == 0 or ext.len > max_ext_len) return false;
    if (program.len > max_program_len) return false;

    if (find_mut(ext)) |existing| {

        @memcpy(existing.program[0..program.len], program);
        existing.program_len = @intCast(program.len);
        existing.kind = kind;
        existing.enabled = enabled;

        return true;

    }

    if (slot_count >= max_handlers) return false;

    var slot: Slot = .{

        .kind = kind,
        .enabled = enabled,

    };

    @memcpy(slot.ext[0..ext.len], ext);
    slot.ext_len = @intCast(ext.len);
    @memcpy(slot.program[0..program.len], program);
    slot.program_len = @intCast(program.len);

    // Normalize extension to lowercase.
    for (slot.ext[0..slot.ext_len]) |*byte| {

        if (byte.* >= 'A' and byte.* <= 'Z') byte.* += 32;

    }

    slots[slot_count] = slot;
    slot_count += 1;

    return true;

}

fn find_mut(ext: []const u8) ?*Slot {

    for (slots[0..slot_count]) |*slot| {

        if (eql_ascii_ignore_case(slot.extension(), ext)) return slot;

    }

    return null;

}

fn trim_ascii(text: []const u8) []const u8 {

    var start: usize = 0;
    var end = text.len;

    while (start < end and (text[start] == ' ' or text[start] == '\t' or text[start] == '\r')) start += 1;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r')) end -= 1;

    return text[start..end];

}

fn eql_ascii_ignore_case(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;

        if (lx != ly) return false;

    }

    return true;

}

const testing = std.testing;

test "handler defaults match image and audio extensions" {

    reset_defaults();

    const png = match("photo.PNG") orelse return error.TestUnexpectedResult;

    try testing.expect(png.kind == .image);
    try testing.expectEqualStrings("viewer", png.app());
    try testing.expect(match("shot.jpeg") == null);

    const wav = match("beep.wav") orelse return error.TestUnexpectedResult;

    try testing.expect(wav.kind == .audio);
    try testing.expect(match("notes.txt") == null);

}

test "handler cycle and config round-trip" {

    reset_defaults();

    cycle(0); // png: viewer -> notepad
    try testing.expectEqualStrings("notepad", at(0).?.app());

    cycle(0); // notepad -> audio-gui
    cycle(0); // audio-gui -> disabled
    try testing.expect(!at(0).?.enabled);

    var buffer: [256]u8 = undefined;
    const written = write_config(&buffer);

    reset_defaults();
    apply_config_line("open.png=");

    try testing.expect(match("a.png") == null);

    var lines = std.mem.tokenizeScalar(u8, buffer[0..written], '\n');

    while (lines.next()) |line| {

        if (line.len != 0) apply_config_line(line);

    }

    try testing.expect(match("a.png") == null);

}
