// Calculator: a compact four-function calculator with percent, sign toggle, and continuous entry.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Calculator",
    .description = "Execute simple calculations.",
    .icon = "calculator",
    .category = "Accessories",
};

comptime {

    _ = lib.start;

}

const pad: i32 = 10;
const display_h: i32 = 64;
const btn_gap: i32 = 6;

const Op = enum {

    none,
    add,
    sub,
    mul,
    div,

};

var font: lib.draw.text.Face = undefined;
var keyboard: lib.keymap.Keyboard = .{};

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

// Deliberate exception to the no-float rule: the kernel does not preserve FP/SIMD registers across context switches, so this arithmetic is only safe as long as no preemption lands between dependent FP instructions.

var display_value: f64 = 0;
var stored: f64 = 0;
var pending: Op = .none;
var entering = false;
var error_state = false;

var display_text: [32]u8 = undefined;
var display_len: usize = 1;

var regions = ui.HitRegions{};

const Key = enum {

    clear,
    sign,
    percent,
    divide,
    seven,
    eight,
    nine,
    multiply,
    four,
    five,
    six,
    subtract,
    one,
    two,
    three,
    add,
    zero,
    decimal,
    equals,

};

const key_labels = [_][]const u8{

    "C", "+/-", "%", "/",
    "7", "8", "9", "*",
    "4", "5", "6", "-",
    "1", "2", "3", "+",
    "0", ".", "=",

};

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(280, 380, lib.proto.window.flag_quartz, "Calculator");

    set_display_text("0");
    paint();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                paint();

            },

            events.kind_button_down => {

                if (event.code == events.button_left) click(event.x, event.y);

            },

            events.kind_key_down => key_down(event.code),

            events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

            events.kind_pointer_move => {

                if (regions.pointer_move(event.x, event.y)) paint();

                update_cursor(event.x, event.y);

            },

            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                paint();

            },

            else => {},

        }

    }

}

fn update_cursor(x: i32, y: i32) void {

    if (key_at(x, y) != null) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn key_down(code: u16) void {

    // Digit row and numpad-style keys via scancode-independent char mapping when available.
    if (keyboard.modifier(events.kind_key_down, code)) return;

    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len != 1) return;

    switch (bytes[0]) {

        '0' => press(.zero),
        '1' => press(.one),
        '2' => press(.two),
        '3' => press(.three),
        '4' => press(.four),
        '5' => press(.five),
        '6' => press(.six),
        '7' => press(.seven),
        '8' => press(.eight),
        '9' => press(.nine),
        '.' => press(.decimal),
        '+' => press(.add),
        '-' => press(.subtract),
        '*' => press(.multiply),
        '/' => press(.divide),
        '%' => press(.percent),
        '\r', '=' => press(.equals),
        0x08, 0x7f => press(.clear),
        'c', 'C' => press(.clear),
        else => {},

    }

}

fn click(x: i32, y: i32) void {

    const key = key_at(x, y) orelse return;

    press(key);

}

fn press(key: Key) void {

    if (error_state and key != .clear) return;

    switch (key) {

        .clear => {

            display_value = 0;
            stored = 0;
            pending = .none;
            entering = false;
            error_state = false;
            set_display_text("0");

        },

        .sign => {

            display_value = -display_value;
            sync_display_from_value();

        },

        .percent => {

            display_value /= 100.0;
            entering = false;
            sync_display_from_value();

        },

        .decimal => input_decimal(),

        .zero => input_digit(0),
        .one => input_digit(1),
        .two => input_digit(2),
        .three => input_digit(3),
        .four => input_digit(4),
        .five => input_digit(5),
        .six => input_digit(6),
        .seven => input_digit(7),
        .eight => input_digit(8),
        .nine => input_digit(9),

        .add => set_op(.add),
        .subtract => set_op(.sub),
        .multiply => set_op(.mul),
        .divide => set_op(.div),

        .equals => {

            apply_pending();
            pending = .none;
            entering = false;

        },

    }

    paint();

}

fn input_digit(digit: u8) void {

    if (!entering) {

        set_display_text("0");
        entering = true;

    }

    const text = display_text[0..display_len];

    if (text.len == 1 and text[0] == '0') {

        display_text[0] = '0' + digit;
        display_len = 1;

    } else if (display_len < 16) {

        display_text[display_len] = '0' + digit;
        display_len += 1;

    }

    display_value = parse_display();

}

fn input_decimal() void {

    if (!entering) {

        set_display_text("0");
        entering = true;

    }

    const text = display_text[0..display_len];

    for (text) |byte| {

        if (byte == '.') return;

    }

    if (display_len >= 16) return;

    display_text[display_len] = '.';
    display_len += 1;

}

fn set_op(op: Op) void {

    if (entering or pending == .none) apply_pending();

    stored = display_value;
    pending = op;
    entering = false;

}

fn apply_pending() void {

    if (pending == .none) return;

    const a = stored;
    const b = display_value;

    const result: f64 = switch (pending) {

        .none => b,
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => if (b == 0.0) blk: {

            error_state = true;
            set_display_text("Error");
            break :blk 0;

        } else a / b,

    };

    if (error_state) return;

    display_value = result;
    stored = result;
    sync_display_from_value();

}

fn parse_display() f64 {

    return std.fmt.parseFloat(f64, display_text[0..display_len]) catch 0;

}

fn sync_display_from_value() void {

    if (error_state) return;

    // Prefer integer display when the value is integral and in range.
    if (display_value == @trunc(display_value) and @abs(display_value) < 1e15) {

        const as_int: i64 = @intFromFloat(display_value);
        const text = std.fmt.bufPrint(&display_text, "{d}", .{as_int}) catch {

            set_display_text("Error");
            error_state = true;
            return;

        };

        display_len = text.len;
        return;

    }

    const text = std.fmt.bufPrint(&display_text, "{d:.8}", .{display_value}) catch {

        set_display_text("Error");
        error_state = true;
        return;

    };

    // Trim trailing zeros after the decimal point.
    var length = text.len;

    if (std.mem.indexOfScalar(u8, text, '.')) |_| {

        while (length > 0 and display_text[length - 1] == '0') : (length -= 1) {}
        if (length > 0 and display_text[length - 1] == '.') length -= 1;

    }

    display_len = length;

}

fn set_display_text(text: []const u8) void {

    const length = @min(text.len, display_text.len);

    @memcpy(display_text[0..length], text[0..length]);
    display_len = length;

}

fn grid_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return .{

        .x = pad,
        .y = pad + display_h + pad,
        .w = width - 2 * pad,
        .h = height - display_h - 3 * pad,

    };

}

fn key_rect(index: usize) Rect {

    const grid = ui.Grid{ .rect = grid_rect(), .columns = 4, .rows = 5, .gap = btn_gap };
    const row: i32 = @intCast(index / 4);

    // Zero spans two columns; decimal and equals fill out the bottom row.
    if (index == @intFromEnum(Key.zero)) return grid.cell(0, row, 2);
    if (index == @intFromEnum(Key.decimal)) return grid.cell(2, row, 1);
    if (index == @intFromEnum(Key.equals)) return grid.cell(3, row, 1);

    return grid.cell(@intCast(index % 4), row, 1);

}

fn key_at(x: i32, y: i32) ?Key {

    const id = regions.hit(x, y);

    if (id == 0) return null;

    return @enumFromInt(id - 1);

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    lib.quartz.fill_window(surface, ui.theme.window_bg, @intFromEnum(lib.prefs.quartz_level));

    const display = Rect{ .x = pad, .y = pad, .w = width - 2 * pad, .h = display_h };

    ui.fill_round_rect(surface, display, 8, ui.theme.surface);
    ui.stroke_round_rect(surface, display, 8, 1, ui.theme.border);

    const text = display_text[0..display_len];
    const size: u32 = 22;
    const visible = ui.truncate(&font, text, size, display.w - 20);
    const text_w = font.text_width(visible, size);
    const text_x = display.x + display.w - 12 - text_w;
    const text_y = display.y + @divTrunc(display.h - font.line_height(size), 2);

    font.draw(surface, text_x, text_y, size, visible, if (error_state) ui.theme.warn else ui.theme.text);

    regions.reset();

    var index: usize = 0;

    while (index < key_labels.len) : (index += 1) {

        const rect = key_rect(index);
        const id: u32 = @intCast(index + 1);
        const is_op = index == 3 or index == 7 or index == 11 or index == 15 or index == 18;

        regions.add(id, rect);

        ui.widgets.button(surface, &font, rect, key_labels[index], .{

            .hovered = regions.hovered(id),
            .accent = is_op,

        }, .{ .size = 16 });

    }

    window.present_all() catch {};

}
