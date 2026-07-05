// write: interactive TUI editor, or pipe/argument mode when stdin is not a TTY.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

const file_max: usize = 4095;

var content: [file_max + 1]u8 = undefined;
var content_len: usize = 0;
var cursor_pos: usize = 0;
var scroll_row: usize = 0;

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 2) {

        lib.io.writeln(out, "usage: write <path> [text ...]") catch {};

        return 1;

    }

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "write: filesystem unavailable") catch {};

        return 1;

    };

    if (args.len > 2) return write_args(&client, out, args[1], args[2..]);

    if (!lib.term.is_tty()) return write_stdin(&client, args[1]);

    return run_tui(&client, out, args[1]);

}

fn write_args(client: *lib.fs.Client, out: *lib.stream.Stream, path: []const u8, words: []const []const u8) u8 {

    const flags = lib.proto.filesystem.open_create | lib.proto.filesystem.open_truncate;
    const file = client.open_path(path, flags) catch |failure| {

        lib.io.print(out, "write: {s}: {s}\n", .{ path, lib.fs.describe(failure) }) catch {};

        return 1;

    };

    var offset: u64 = 0;

    for (words, 0..) |word, index| {

        if (index > 0) offset += put(client, file, offset, " ") catch return 1;

        offset += put(client, file, offset, word) catch return 1;

    }

    _ = put(client, file, offset, "\n") catch return 1;

    client.close_file(file) catch {};

    return 0;

}

fn write_stdin(client: *lib.fs.Client, path: []const u8) u8 {

    const flags = lib.proto.filesystem.open_create | lib.proto.filesystem.open_truncate;
    const file = client.open_path(path, flags) catch return 1;

    var input = lib.start.stdin() catch return 1;
    var buffer: [1024]u8 = undefined;
    var offset: u64 = 0;

    while (true) {

        const length = input.read(&buffer) catch return 1;

        if (length == 0) break;

        offset += put(client, file, offset, buffer[0..length]) catch return 1;

    }

    client.close_file(file) catch {};

    return 0;

}

fn run_tui(client: *lib.fs.Client, out: *lib.stream.Stream, path: []const u8) u8 {

    var input = lib.start.stdin() catch return 1;

    content_len = 0;
    cursor_pos = 0;
    scroll_row = 0;

    if (client.open_path(path, 0)) |file| {

        var offset: u64 = 0;
        var buffer: [1024]u8 = undefined;

        while (content_len < file_max) {

            const length = client.read(file, offset, &buffer) catch break;

            if (length == 0) break;

            const amount = @min(length, file_max - content_len);

            @memcpy(content[content_len..][0..amount], buffer[0..amount]);
            content_len += amount;
            offset += length;

        }

        client.close_file(file) catch {};

    } else |_| {}

    lib.term.set_raw(&input) catch return 1;
    defer lib.term.set_cooked(&input) catch {};

    lib.term.clear_screen(out) catch return 1;
    draw(out, path) catch return 1;

    while (true) {

        const byte = lib.term.read_char(&input) catch return 1;

        if (byte == 0x1B) {

            const next = lib.term.read_char(&input) catch return 1;

            if (next == 'c') {

                lib.term.clear_screen(out) catch {};
                return 0;

            }

            if (next == 's') {

                save(client, path) catch return 1;
                lib.term.clear_screen(out) catch {};
                return 0;

            }

            if (next == '[' or next == 'O') {

                switch (lib.term.read_char(&input) catch return 1) {
                    'A' => move_up(),
                    'B' => move_down(),
                    'C' => move_right(),
                    'D' => move_left(),
                    else => {},
                }

            }

            draw(out, path) catch return 1;
            continue;

        }

        if (byte == 0x08 or byte == 0x7F) {

            delete_before();
            draw(out, path) catch return 1;
            continue;

        }

        if (byte == '\r' or byte == '\n') {

            insert_char('\n');
            draw(out, path) catch return 1;
            continue;

        }

        if (byte >= 0x20 and byte < 0x7F) {

            insert_char(byte);
            draw(out, path) catch return 1;
            continue;

        }

    }

}

fn save(client: *lib.fs.Client, path: []const u8) !void {

    _ = client.delete(path) catch {};
    try client.create(path, lib.proto.filesystem.kind_file);

    const file = try client.open_path(path, 0);
    defer client.close_file(file) catch {};

    var offset: u64 = 0;

    while (offset < content_len) {

        const written = try client.write(file, offset, content[@intCast(offset)..content_len]);

        if (written == 0) return error.Gone;

        offset += written;

    }

}

fn draw(out: *lib.stream.Stream, path: []const u8) !void {

    const rc = cursor_row_col();

    if (rc.row < scroll_row) scroll_row = rc.row;
    if (rc.row >= scroll_row + lib.term.content_rows) scroll_row = rc.row - lib.term.content_rows + 1;

    try lib.term.home(out);

    try lib.term.write(out, path);
    try lib.term.write(out, " | ");
    try lib.term.print_int(out, content_len);
    try lib.term.write(out, " Bytes");
    try lib.term.clear_line(out);
    try lib.term.write(out, "\r\n");
    try lib.term.clear_line(out);
    try lib.term.write(out, "\r\n");

    var pos: usize = 0;
    var skip: usize = 0;

    while (skip < scroll_row and pos < content_len) {

        if (content[pos] == '\n') skip += 1;

        pos += 1;

    }

    var lines: usize = 0;

    while (lines < lib.term.content_rows) : (lines += 1) {

        const line_start = pos;

        while (pos < content_len and content[pos] != '\n') pos += 1;

        if (pos > line_start) try lib.term.write(out, content[line_start..pos]);

        try lib.term.clear_line(out);
        try lib.term.write(out, "\r\n");

        if (pos < content_len) pos += 1;

    }

    try lib.term.clear_line(out);
    try lib.term.write(out, "\r\n");
    try lib.term.write(out, "Exit (Alt+C) | Save (Alt+S)");
    try lib.term.clear_line(out);

    const disp_row: usize = 3 + (if (rc.row >= scroll_row) rc.row - scroll_row else 0);
    const disp_col: usize = rc.col + 1;

    try lib.term.move_cursor(out, disp_row, disp_col);

}

const RowCol = struct { row: usize, col: usize };

fn cursor_row_col() RowCol {

    var row: usize = 0;
    var col: usize = 0;

    for (content[0..cursor_pos]) |ch| {

        if (ch == '\n') {

            row += 1;
            col = 0;

        } else {

            col += 1;

        }

    }

    return .{ .row = row, .col = col };

}

fn row_start(target: usize) usize {

    if (target == 0) return 0;

    var row: usize = 0;

    for (content[0..content_len], 0..) |ch, index| {

        if (ch == '\n') {

            row += 1;

            if (row == target) return index + 1;

        }

    }

    return content_len;

}

fn row_len(target: usize) usize {

    const start = row_start(target);
    var end = start;

    while (end < content_len and content[end] != '\n') end += 1;

    return end - start;

}

fn move_up() void {

    const rc = cursor_row_col();

    if (rc.row == 0) return;

    const prev_start = row_start(rc.row - 1);
    const prev_len = row_len(rc.row - 1);

    cursor_pos = prev_start + @min(rc.col, prev_len);

}

fn move_down() void {

    const rc = cursor_row_col();
    const next_row = rc.row + 1;
    const next_start = row_start(next_row);

    if (next_start >= content_len and content_len > 0 and content[content_len - 1] != '\n') return;
    if (next_start > content_len) return;

    const next_len = row_len(next_row);

    cursor_pos = next_start + @min(rc.col, next_len);

}

fn move_left() void {

    if (cursor_pos > 0) cursor_pos -= 1;

}

fn move_right() void {

    if (cursor_pos < content_len) cursor_pos += 1;

}

fn insert_char(ch: u8) void {

    if (content_len >= file_max) return;

    var index = content_len;

    while (index > cursor_pos) : (index -= 1) content[index] = content[index - 1];

    content[cursor_pos] = ch;
    content_len += 1;
    cursor_pos += 1;

}

fn delete_before() void {

    if (cursor_pos == 0) return;

    cursor_pos -= 1;

    var index = cursor_pos;

    while (index < content_len - 1) : (index += 1) content[index] = content[index + 1];

    content_len -= 1;

}

fn put(client: *lib.fs.Client, file: u64, offset: u64, bytes: []const u8) !u64 {

    var written: u64 = 0;

    while (written < bytes.len) {

        written += try client.write(file, offset + written, bytes[@intCast(written)..]);

    }

    return written;

}
