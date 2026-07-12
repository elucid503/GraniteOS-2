// view: less-like pager for a file, or a plain dump when stdout is piped.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

const file_max: usize = 65535;

var content: [file_max + 1]u8 = undefined;
var content_len: usize = 0;
var line_count: usize = 0;
var scroll_row: usize = 0;

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 2) {

        lib.io.writeln(out, "usage: view <path>") catch {};

        return 1;

    }

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "view: filesystem unavailable") catch {};

        return 1;

    };
    defer client.close();

    const file = client.open_path(args[1], 0) catch |failure| {

        lib.io.print(out, "view: {s}: {s}\n", .{ args[1], lib.fs.describe(failure) }) catch {};

        return 1;

    };

    content_len = 0;

    var offset: u64 = 0;
    var buffer: [1024]u8 = undefined;

    while (content_len < file_max) {

        const length = client.read(file, offset, &buffer) catch {

            client.close_file(file) catch {};

            return 1;

        };

        if (length == 0) break;

        const amount = @min(length, file_max - content_len);

        @memcpy(content[content_len..][0..amount], buffer[0..amount]);
        content_len += amount;
        offset += length;

    }

    client.close_file(file) catch {};

    line_count = count_lines();

    if (!lib.term.is_tty()) return dump(out);

    return run_pager(out, args[1]);

}

fn dump(out: *lib.stream.Stream) u8 {

    var cursor: usize = 0;

    while (cursor < content_len) {

        if (content[cursor] == '\n') {

            lib.io.write(out, "\r\n") catch return 1;

        } else {

            lib.io.write(out, content[cursor .. cursor + 1]) catch return 1;

        }

        cursor += 1;

    }

    return 0;

}

fn run_pager(out: *lib.stream.Stream, path: []const u8) u8 {

    var input = lib.start.stdin() catch return 1;

    scroll_row = 0;

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

            if (next == '[' or next == 'O') {

                switch (lib.term.read_char(&input) catch return 1) {
                    'A' => scroll_up(1),
                    'B' => scroll_down(1),
                    'C' => {},
                    'D' => {},
                    else => {},
                }

            }

            draw(out, path) catch return 1;
            continue;

        }

        if (byte == ' ' or byte == 'j' or byte == 'J') {

            scroll_down(lib.term.content_rows);
            draw(out, path) catch return 1;
            continue;

        }

        if (byte == 'b' or byte == 'B' or byte == 'k' or byte == 'K') {

            scroll_up(lib.term.content_rows);
            draw(out, path) catch return 1;
            continue;

        }

    }

}

fn draw(out: *lib.stream.Stream, path: []const u8) !void {

    const visible = @min(lib.term.content_rows, if (line_count > scroll_row) line_count - scroll_row else 0);
    const first = scroll_row + 1;
    const last = scroll_row + visible;

    try lib.term.home(out);

    try lib.term.write(out, path);
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
    try lib.term.write(out, "Lines ");
    try lib.term.print_int(out, if (line_count == 0) 0 else first);
    try lib.term.write(out, "-");
    try lib.term.print_int(out, if (line_count == 0) 0 else last);
    try lib.term.write(out, " of ");
    try lib.term.print_int(out, line_count);
    try lib.term.write(out, " | Exit (Alt+C)");
    try lib.term.clear_line(out);

}

fn count_lines() usize {

    if (content_len == 0) return 0;

    var lines: usize = 1;

    for (content[0..content_len]) |ch| {

        if (ch == '\n') lines += 1;

    }

    return lines;

}

fn scroll_up(amount: usize) void {

    if (scroll_row >= amount) {

        scroll_row -= amount;

    } else {

        scroll_row = 0;

    }

}

fn scroll_down(amount: usize) void {

    if (line_count == 0) return;

    const max_scroll = if (line_count > lib.term.content_rows) line_count - lib.term.content_rows else 0;

    scroll_row = @min(scroll_row + amount, max_scroll);

}
