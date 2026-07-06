// The M9 welcome screen: a fullscreen window with the system title and a click-to-continue prompt. Exiting
// after the click is the hand-off - Flint's supervisor sees this process's death and spawns the demo screen.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const color_top = gfx.rgb(12, 12, 14);
const color_bottom = gfx.rgb(42, 42, 46);
const color_title = gfx.rgb(244, 246, 252);
const color_subtitle = gfx.rgb(178, 178, 184);
const color_accent = gfx.rgb(214, 214, 220);

var title_font: ?lib.font.Font = null;
var body_font: ?lib.font.Font = null;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try load_fonts();

    var connection = try connect();
    var window = try connection.create_window(0, 0, lib.proto.window.flag_fullscreen, "welcome");

    draw(&window.surface);
    gfx.fence();
    try window.present_all();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_button_down => break,

            events.kind_window_resize => {

                try window.resize(@intCast(event.x), @intCast(event.y));

                draw(&window.surface);
                gfx.fence();
                try window.present_all();

            },

            else => {},

        }

    }

    window.destroy();

}

// The compositor may still be registering its name while this program starts; retry the lookup briefly.

fn connect() !lib.window.Connection {

    var attempts: usize = 0;

    while (true) {

        return lib.window.Connection.connect(cap.memory) catch |failure| {

            attempts += 1;

            if (attempts > 200) return failure;

            sys.yield();

            continue;

        };

    }

}

fn load_fonts() !void {

    const length: usize = @intCast(lib.start.word(3));
    const offset: usize = @intCast(lib.start.word(4));

    const base = try sys.map(cap.self_space, cap.gui.bundle, 0, sys.read);
    const bundle = try lib.bundle.Bundle.open(base + offset, length);

    title_font = lib.font.Font.parse(bundle.find("font-title") orelse return error.NotFound) catch return error.Invalid;
    body_font = lib.font.Font.parse(bundle.find("font") orelse return error.NotFound) catch return error.Invalid;

}

fn draw(surface: *const gfx.Surface) void {

    const bounds = surface.bounds();
    const center_x = @divTrunc(bounds.w, 2);
    const center_y = @divTrunc(bounds.h, 2);

    surface.fill_gradient(bounds, color_top, color_bottom);

    if (title_font) |*font| {

        const text = "GraniteOS 2";
        const x = center_x - @divTrunc(font.text_width(text), 2);
        const y = center_y - @as(i32, @intCast(font.height));

        font.draw(surface, x, y, text, color_title);

        // An accent rule under the title.

        const rule_y = y + @as(i32, @intCast(font.height)) + 12;

        surface.fill_rect(.{ .x = center_x - 120, .y = rule_y, .w = 240, .h = 2 }, color_accent);

    }

    if (body_font) |*font| {

        const text = "Click anywhere to continue";
        const x = center_x - @divTrunc(font.text_width(text), 2);
        const y = center_y + 44;

        font.draw(surface, x, y, text, color_subtitle);

    }

}
