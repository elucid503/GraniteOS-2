// The M9 test screen (disposable by design): windows exercising text, focus, close, and dragging.
// Closing every window exits; Flint's supervisor then brings the welcome screen back.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const color_backdrop = gfx.rgb(0, 0, 0);
const color_text = gfx.rgb(220, 224, 232);
const color_dim = gfx.rgb(150, 156, 170);

const wrapped_text =
    "This box demonstrates word-wrapped text rendered from a real PSF bitmap font file. " ++
    "Long words like antidisestablishmentarianism hard-break cleanly, and manual breaks work too.\n\n" ++
    "Drag any window by its title bar. Click a window to focus and raise it. " ++
    "The close box destroys just that window.";

var body_font: ?lib.font.Font = null;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try load_font();

    var connection = try connect();

    var text = try connection.create_window(360, 260, 0, "Wrapped text");
    var about = try connection.create_window(300, 150, 0, "About this screen");

    draw_text(&text.surface);
    draw_about(&about.surface);

    try text.present_all();
    try about.present_all();

    var text_open = true;
    var about_open = true;

    while (text_open or about_open) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                if (text_open and event.window == text.id) {

                    text.destroy();
                    text_open = false;

                } else if (about_open and event.window == about.id) {

                    about.destroy();
                    about_open = false;

                }

            },

            else => {},

        }

    }

}

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

fn load_font() !void {

    const length: usize = @intCast(lib.start.word(3));
    const offset: usize = @intCast(lib.start.word(4));

    const base = try sys.map(cap.self_space, cap.gui.bundle, 0, sys.read);
    const bundle = try lib.bundle.Bundle.open(base + offset, length);

    body_font = lib.font.Font.parse(bundle.find("font") orelse return error.NotFound) catch return error.Invalid;

}

fn draw_text(surface: *const gfx.Surface) void {

    surface.fill(color_backdrop);

    if (body_font) |*font| {

        _ = font.draw_wrapped(surface, .{

            .x = 12,
            .y = 12,

            .w = surface.bounds().w - 24,
            .h = surface.bounds().h - 24,

        }, wrapped_text, color_text);

    }

}

fn draw_about(surface: *const gfx.Surface) void {

    surface.fill(color_backdrop);

    if (body_font) |*font| {

        _ = font.draw_wrapped(surface, .{

            .x = 12,
            .y = 12,

            .w = surface.bounds().w - 24,
            .h = surface.bounds().h - 24,

        }, "A disposable M9 test screen. Close every window to return to the welcome screen.", color_dim);

    }

}
