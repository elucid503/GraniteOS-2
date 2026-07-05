// Interactive line input for Marble: history, cursor movement, and filesystem path completion.

const std = @import("std");

const fs = @import("../fs/fs.zig");
const io = @import("../io/io.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const term = @import("../io/term.zig");

pub const Error = term.Error;

const max_line = 256;
const max_history = 32;
const max_matches = 64;
const max_path = 512;
const max_name = 48;
const render_capacity = max_line + max_path + 64;

pub const Config = struct {

    shell: []const u8,
    cwd: []const u8,
    files: ?*fs.Client,

};

var history: [max_history][max_line]u8 = undefined;
var history_len: [max_history]u8 = undefined;
var history_count: usize = 0;

var match_names: [max_matches][max_name]u8 = undefined;
var match_len: [max_matches]u8 = undefined;

pub fn read(input: *stream.Stream, out: *stream.Stream, buffer: []u8, config: Config) Error!usize {

    if (!term.is_tty()) return input.read(buffer);

    if (buffer.len > max_line) return error.Invalid;

    try term.set_raw(input);
    defer term.set_cooked(input) catch {};

    var editor = Editor{
        .buffer = buffer,
        .config = config,
    };

    try editor.draw(out);

    while (true) {

        const byte = try term.read_char(input);

        if (byte == 0x1B) {

            if (try handle_escape(input, &editor, out)) return editor.len;

            continue;

        }

        if (byte == '\r' or byte == '\n') {

            try io.write(out, "\n");
            push_history(editor.buffer[0..editor.len]);

            return editor.len;

        }

        if (byte == '\t') {

            try editor.complete(out);
            continue;

        }

        if (byte == 0x08 or byte == 0x7F) {

            editor.delete_before();
            try editor.draw(out);
            continue;

        }

        if (byte >= 0x20 and byte < 0x7F) {

            editor.insert(byte);
            try editor.draw(out);
            continue;

        }

    }

}

fn handle_escape(input: *stream.Stream, editor: *Editor, out: *stream.Stream) Error!bool {

    const lead = try term.read_char(input);

    if (lead == 'O') {

        try editor.apply_arrow(try term.read_char(input), out);
        return false;

    }

    if (lead != '[') return false;

    try editor.apply_arrow(try read_csi_final(input), out);

    return false;

}

fn read_csi_final(input: *stream.Stream) Error!u8 {

    var byte = try term.read_char(input);

    while (byte == ';' or (byte >= '0' and byte <= '9')) {

        byte = try term.read_char(input);

    }

    return byte;

}

const Editor = struct {

    buffer: []u8,
    len: usize = 0,
    cursor: usize = 0,
    config: Config,

    draft: [max_line]u8 = undefined,
    draft_len: usize = 0,
    history_index: ?usize = null,

    match_count: usize = 0,
    match_pick: usize = 0,
    complete_start: usize = 0,
    complete_end: usize = 0,
    last_visible_end: usize = 0,

    fn draw(self: *Editor, out: *stream.Stream) Error!void {

        var scratch: [render_capacity]u8 = undefined;
        var offset: usize = 0;

        scratch[offset] = '\r';
        offset += 1;

        offset = try append_prompt(&scratch, offset, self.config);
        offset = try append_slice(&scratch, offset, self.buffer[0..self.len]);

        const visible_end = prompt_cols(self.config) + self.len;
        const pad = if (visible_end < self.last_visible_end) self.last_visible_end - visible_end else 0;

        offset = try append_fill(&scratch, offset, pad, ' ');

        offset = try append_fill(&scratch, offset, self.len - self.cursor + pad, '\x08');

        self.last_visible_end = visible_end;

        try io.write(out, scratch[0..offset]);

    }

    fn apply_arrow(self: *Editor, key: u8, out: *stream.Stream) Error!void {

        switch (key) {

            'A' => self.history_up(),

            'B' => self.history_down(),

            'C' => {
                if (self.cursor < self.len) self.cursor += 1;
            },

            'D' => {
                if (self.cursor > 0) self.cursor -= 1;
            },

            else => return,

        }

        try self.draw(out);

    }

    fn insert(self: *Editor, byte: u8) void {

        if (self.len >= self.buffer.len) return;

        self.clear_completion();

        if (self.history_index) |_| self.leave_history();

        if (self.cursor < self.len) {

            @memcpy(self.buffer[self.cursor + 1 .. self.len + 1], self.buffer[self.cursor..self.len]);

        }

        self.buffer[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;

    }

    fn delete_before(self: *Editor) void {

        if (self.cursor == 0) return;

        self.clear_completion();

        if (self.history_index) |_| self.leave_history();

        @memcpy(self.buffer[self.cursor - 1 .. self.len - 1], self.buffer[self.cursor..self.len]);

        self.len -= 1;
        self.cursor -= 1;

    }

    fn history_up(self: *Editor) void {

        if (history_count == 0) return;

        if (self.history_index == null) {

            self.draft_len = self.len;
            @memcpy(self.draft[0..self.len], self.buffer[0..self.len]);
            self.history_index = history_count - 1;

        } else if (self.history_index.? > 0) {

            self.history_index.? -= 1;

        } else {

            return;

        }

        self.load_history(self.history_index.?);

    }

    fn history_down(self: *Editor) void {

        const index = self.history_index orelse return;

        if (index + 1 < history_count) {

            self.history_index = index + 1;
            self.load_history(self.history_index.?);

        } else {

            self.history_index = null;
            self.len = self.draft_len;
            self.cursor = self.draft_len;
            @memcpy(self.buffer[0..self.draft_len], self.draft[0..self.draft_len]);

        }

    }

    fn load_history(self: *Editor, index: usize) void {

        const amount: usize = history_len[index];
        const source = history[index][0..amount];

        @memcpy(self.buffer[0..amount], source);
        self.len = amount;
        self.cursor = amount;
        self.clear_completion();

    }

    fn leave_history(self: *Editor) void {

        self.history_index = null;

    }

    fn clear_completion(self: *Editor) void {

        self.match_count = 0;
        self.match_pick = 0;
        self.complete_start = 0;
        self.complete_end = 0;

    }

    fn complete(self: *Editor, out: *stream.Stream) Error!void {

        const client = self.config.files orelse return;
        const bounds = word_bounds(self.buffer[0..self.len], self.cursor);

        if (bounds.start == bounds.end) return;

        if (self.match_count > 0 and
            self.complete_start == bounds.start and
            self.complete_end == bounds.end)
        {

            self.match_pick = (self.match_pick + 1) % self.match_count;
            try self.apply_match(out, bounds);
            return;

        }

        const word = self.buffer[bounds.start..bounds.end];
        const matches = find_path_matches(client, self.config.cwd, word) catch return;

        self.complete_start = bounds.start;
        self.complete_end = bounds.end;
        self.match_count = matches;
        self.match_pick = 0;

        if (matches == 0) return;

        if (matches == 1) {

            try self.apply_match(out, bounds);
            return;

        }

        const shared = common_prefix(0, matches);
        const typed_prefix = basename_prefix(word);

        if (shared > typed_prefix.len) {

            const partial = self.buffer[bounds.start..bounds.end];
            var replacement: [max_path]u8 = undefined;
            const replace_len = try format_completion(partial, match_names[0][0..shared], false, &replacement);

            try self.replace_word(out, bounds, replacement[0..replace_len]);
            return;

        }

        try self.show_matches(out);
        try self.apply_match(out, bounds);

    }

    fn apply_match(self: *Editor, out: *stream.Stream, bounds: WordBounds) Error!void {

        const word = self.buffer[bounds.start..bounds.end];
        const amount: usize = match_len[self.match_pick];
        const name = match_names[self.match_pick][0..amount];

        var replacement: [max_path]u8 = undefined;
        const replace_len = try format_completion(word, name, match_is_dir[self.match_pick], &replacement);

        try self.replace_word(out, bounds, replacement[0..replace_len]);

    }

    fn replace_word(self: *Editor, out: *stream.Stream, bounds: WordBounds, replacement: []const u8) Error!void {

        const tail = self.len - bounds.end;
        const room = self.buffer.len - bounds.start;

        if (replacement.len + tail > room) return error.Invalid;

        @memcpy(self.buffer[bounds.start + replacement.len .. bounds.start + replacement.len + tail], self.buffer[bounds.end..][0..tail]);

        @memcpy(self.buffer[bounds.start .. bounds.start + replacement.len], replacement);

        self.len = bounds.start + replacement.len + tail;
        self.cursor = bounds.start + replacement.len;

        if (self.history_index) |_| self.leave_history();

        try self.draw(out);

    }

    fn show_matches(self: *Editor, out: *stream.Stream) Error!void {

        try io.write(out, "\n");

        var index: usize = 0;

        while (index < self.match_count) : (index += 1) {

            if (index != 0) try io.write(out, "  ");

            const amount: usize = match_len[index];

            try io.write(out, match_names[index][0..amount]);

            if (match_is_dir[index]) try io.write(out, "/");

        }

        try io.write(out, "\n");

    }

};

var match_is_dir: [max_matches]bool = undefined;

const WordBounds = struct {

    start: usize,
    end: usize,

};

fn word_bounds(line: []const u8, cursor: usize) WordBounds {

    const clamped = @min(cursor, line.len);
    var start = clamped;

    while (start > 0 and !is_boundary(line[start - 1])) {

        start -= 1;

    }

    var end = clamped;

    while (end < line.len and !is_boundary(line[end])) {

        end += 1;

    }

    return .{ .start = start, .end = end };

}

fn is_boundary(byte: u8) bool {

    return byte == ' ' or byte == '\t' or byte == '|';

}

fn prompt_cols(config: Config) usize {

    return config.shell.len + config.cwd.len + 6;

}

fn append_prompt(scratch: []u8, offset: usize, config: Config) Error!usize {

    var cursor = offset;

    cursor = try append_slice(scratch, cursor, config.shell);
    cursor = try append_slice(scratch, cursor, " [");
    cursor = try append_slice(scratch, cursor, config.cwd);
    cursor = try append_slice(scratch, cursor, "]> ");

    return cursor;

}

fn append_slice(scratch: []u8, offset: usize, bytes: []const u8) Error!usize {

    if (offset + bytes.len > scratch.len) return error.Invalid;

    @memcpy(scratch[offset .. offset + bytes.len], bytes);

    return offset + bytes.len;

}

fn append_fill(scratch: []u8, offset: usize, count: usize, byte: u8) Error!usize {

    if (offset + count > scratch.len) return error.Invalid;

    for (0..count) |index| {

        scratch[offset + index] = byte;

    }

    return offset + count;

}

fn push_history(line: []const u8) void {

    if (line.len == 0) return;

    if (history_count > 0) {

        const last = history_count - 1;
        const previous = history[last][0..history_len[last]];

        if (std.mem.eql(u8, previous, line)) return;

    }

    if (history_count < max_history) {

        @memcpy(history[history_count][0..line.len], line);
        history_len[history_count] = @intCast(line.len);
        history_count += 1;

    } else {

        var index: usize = 1;

        while (index < max_history) : (index += 1) {

            const amount: usize = history_len[index];

            @memcpy(history[index - 1][0..amount], history[index][0..amount]);
            history_len[index - 1] = history_len[index];

        }

        @memcpy(history[max_history - 1][0..line.len], line);
        history_len[max_history - 1] = @intCast(line.len);

    }

}

fn find_path_matches(client: *fs.Client, cwd: []const u8, word: []const u8) Error!usize {

    var dir_buffer: [max_path]u8 = undefined;
    var prefix_buffer: [max_name]u8 = undefined;

    const split = split_partial(cwd, word, &dir_buffer, &prefix_buffer) catch return 0;

    const entries = client.list(split.dir) catch return 0;
    var found: usize = 0;

    for (entries) |entry| {

        if (found >= max_matches) break;

        const name = entry.name[0..entry.name_len];

        if (!starts_with(name, split.prefix)) continue;

        const amount = @min(name.len, max_name);

        @memcpy(match_names[found][0..amount], name[0..amount]);
        match_len[found] = @intCast(amount);
        match_is_dir[found] = entry.kind == proto.filesystem.kind_directory;
        found += 1;

    }

    return found;

}

const PathSplit = struct {

    dir: []const u8,
    prefix: []const u8,

};

fn split_partial(cwd: []const u8, word: []const u8, dir_out: []u8, prefix_out: []u8) Error!PathSplit {

    const slash = std.mem.lastIndexOfScalar(u8, word, '/');

    if (slash) |index| {

        const dir_part = word[0..index];
        const base = word[index + 1 ..];

        if (base.len > prefix_out.len) return error.Invalid;

        @memcpy(prefix_out[0..base.len], base);

        const absolute = if (dir_part.len == 0)

            try fs.canonicalize(cwd, "/", dir_out)

        else

            try fs.canonicalize(cwd, dir_part, dir_out);

        return .{

            .dir = absolute,
            .prefix = prefix_out[0..base.len],

        };

    }

    if (word.len > prefix_out.len) return error.Invalid;

    @memcpy(prefix_out[0..word.len], word);

    return .{

        .dir = cwd,
        .prefix = prefix_out[0..word.len],

    };

}

fn format_completion(word: []const u8, name: []const u8, is_dir: bool, out: []u8) Error!usize {

    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    var length: usize = 0;

    if (slash) |index| {

        const dir_part = word[0 .. index + 1];

        if (dir_part.len + name.len + @intFromBool(is_dir) > out.len) return error.Invalid;

        @memcpy(out[0..dir_part.len], dir_part);
        length = dir_part.len;

    }

    if (length + name.len + @intFromBool(is_dir) > out.len) return error.Invalid;

    @memcpy(out[length .. length + name.len], name);
    length += name.len;

    if (is_dir) {

        out[length] = '/';
        length += 1;

    }

    return length;

}

fn starts_with(text: []const u8, prefix: []const u8) bool {

    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);

}

fn basename_prefix(word: []const u8) []const u8 {

    const slash = std.mem.lastIndexOfScalar(u8, word, '/');

    if (slash) |index| return word[index + 1 ..];

    return word;

}

fn common_prefix(start: usize, count: usize) usize {

    if (count == 0) return 0;

    const first: usize = match_len[start];
    var length: usize = first;

    var index = start + 1;

    while (index < start + count) : (index += 1) {

        const amount: usize = match_len[index];
        var shared: usize = 0;

        while (shared < length and shared < amount and
            match_names[start][shared] == match_names[index][shared])
        {

            shared += 1;

        }

        length = shared;

    }

    return length;

}