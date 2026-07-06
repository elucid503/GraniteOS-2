// US keyboard mapping from the Linux evdev keycodes the input server forwards (events.kind_key_down/up carry
// raw KEY_* codes) into the byte stream a text program expects. Shared by the taskbar's search box and the shell
// terminal, so both handle Shift, Caps Lock, Ctrl, and the arrow escape sequences the same way.

const events = @import("gfx/events.zig");

// evdev key codes used for modifiers and navigation.

const key_esc = 1;
const key_backspace = 14;
const key_tab = 15;
const key_enter = 28;
const key_leftctrl = 29;
const key_leftshift = 42;
const key_rightshift = 54;
const key_leftalt = 56;
const key_capslock = 58;
const key_rightctrl = 97;

const key_up = 103;
const key_left = 105;
const key_right = 106;
const key_down = 108;
const key_home = 102;
const key_end = 107;

const base_map = build_base();
const shift_map = build_shift();

pub const Keyboard = struct {

    shift: bool = false,
    ctrl: bool = false,
    caps: bool = false,

    /// Fold a key event into modifier state; returns true when it was a modifier (so it produces no character).
    pub fn modifier(self: *Keyboard, kind: u16, code: u16) bool {

        const down = kind == events.kind_key_down;

        switch (code) {

            key_leftshift, key_rightshift => {

                self.shift = down;
                return true;

            },

            key_leftctrl, key_rightctrl => {

                self.ctrl = down;
                return true;

            },

            key_leftalt => return true,

            key_capslock => {

                if (down) self.caps = !self.caps;
                return true;

            },

            else => return false,

        }

    }

    /// The bytes a key_down for `code` produces given the current modifiers, written into `out`.
    pub fn bytes(self: *const Keyboard, code: u16, out: *[3]u8) []const u8 {

        switch (code) {

            key_up => return escape(out, 'A'),
            key_down => return escape(out, 'B'),
            key_right => return escape(out, 'C'),
            key_left => return escape(out, 'D'),
            key_home => return escape(out, 'H'),
            key_end => return escape(out, 'F'),

            else => {},

        }

        if (code >= base_map.len) return out[0..0];

        var char = if (self.shift) shift_map[code] else base_map[code];

        if (char == 0) return out[0..0];

        if (self.caps and is_letter(char)) char ^= 0x20;

        if (self.ctrl and is_letter(char)) char &= 0x1f;

        out[0] = char;

        return out[0..1];

    }

};

fn escape(out: *[3]u8, final: u8) []const u8 {

    out[0] = 0x1b;
    out[1] = '[';
    out[2] = final;

    return out[0..3];

}

fn is_letter(char: u8) bool {

    const lower = char | 0x20;

    return lower >= 'a' and lower <= 'z';

}

fn build_base() [128]u8 {

    var map = [_]u8{0} ** 128;

    map[key_esc] = 0x1b;
    map[key_backspace] = 0x7f;
    map[key_tab] = '\t';
    map[key_enter] = '\r';

    set_row(&map, "1234567890-=", key_esc + 1);
    set_row(&map, "qwertyuiop[]", key_tab + 1);
    set_row(&map, "asdfghjkl;'`", 30);
    map[43] = '\\';
    set_row(&map, "zxcvbnm,./", 44);
    map[57] = ' ';

    return map;

}

fn build_shift() [128]u8 {

    var map = [_]u8{0} ** 128;

    map[key_esc] = 0x1b;
    map[key_backspace] = 0x7f;
    map[key_tab] = '\t';
    map[key_enter] = '\r';

    set_row(&map, "!@#$%^&*()_+", key_esc + 1);
    set_row(&map, "QWERTYUIOP{}", key_tab + 1);
    set_row(&map, "ASDFGHJKL:\"~", 30);
    map[43] = '|';
    set_row(&map, "ZXCVBNM<>?", 44);
    map[57] = ' ';

    return map;

}

fn set_row(map: *[128]u8, glyphs: []const u8, start: usize) void {

    for (glyphs, 0..) |glyph, index| {

        map[start + index] = glyph;

    }

}
