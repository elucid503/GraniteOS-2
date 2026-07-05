// The M9 test screen (disposable by design): three windows exercising the library and the compositor -
// shapes and gradients, word-wrapped text in a box, and dragging/focus/close across windows from one
// process. Closing every window exits; Flint's supervisor then brings the welcome screen back.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const color_backdrop = gfx.rgb(24, 26, 33);
const color_text = gfx.rgb(220, 224, 232);
const color_dim = gfx.rgb(150, 156, 170);

const accents = [_]gfx.Color{

    gfx.rgb(96, 140, 230),
    gfx.rgb(214, 120, 80),
    gfx.rgb(92, 190, 124),
    gfx.rgb(196, 110, 190),

};

const wrapped_text =
    "This box demonstrates word-wrapped text rendered from a real PSF bitmap font file. " ++
    "Long words like antidisestablishmentarianism hard-break cleanly, and manual breaks work too.\n\n" ++
    "Drag any window by its title bar. Click a window to focus and raise it. " ++
    "The close box destroys just that window.";

var body_font: ?lib.font.Font = null;

var accent_index: usize = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        lib.log.fmt("demo: failed: {s}\n", .{@errorName(failure)});

        return 1;

    };

    return 0;

}

fn run() !void {

    try load_font();

    var connection = try connect();

    var shapes = try connection.create_window(320, 220, 0, "Shapes");
    var text = try connection.create_window(360, 260, 0, "Wrapped text");
    var about = try connection.create_window(300, 150, 0, "About this screen");

    draw_shapes(&shapes.surface);
    draw_text(&text.surface);
    draw_about(&about.surface);

    try shapes.present_all();
    try text.present_all();
    try about.present_all();

    lib.log.line("demo: presented\n");

    var shapes_open = true;
    var text_open = true;
    var about_open = true;

    while (shapes_open or text_open or about_open) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                if (shapes_open and event.window == shapes.id) {

                    shapes.destroy();
                    shapes_open = false;

                } else if (text_open and event.window == text.id) {

                    text.destroy();
                    text_open = false;

                } else if (about_open and event.window == about.id) {

                    about.destroy();
                    about_open = false;

                }

            },

            // Clicking the shapes canvas cycles its accent color: input reaching a client, redrawing,
            // and presenting damage end to end.

            events.kind_button_down => {

                if (shapes_open and event.window == shapes.id) {

                    accent_index = (accent_index + 1) % accents.len;

                    draw_shapes(&shapes.surface);
                    try shapes.present_all();

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

fn draw_shapes(surface: *const gfx.Surface) void {

    const accent = accents[accent_index];
    const bounds = surface.bounds();

    surface.fill(color_backdrop);

    surface.fill_gradient(.{ .x = 12, .y = 12, .w = bounds.w - 24, .h = 48 }, accent, color_backdrop);
    surface.stroke_rect(.{ .x = 12, .y = 12, .w = bounds.w - 24, .h = 48 }, 1, accent);

    surface.fill_circle(60, 120, 34, accent);
    surface.stroke_circle(60, 120, 42, color_dim);

    surface.fill_rounded_rect(.{ .x = 120, .y = 86, .w = 90, .h = 68 }, 12, color_dim);
    surface.fill_rect(.{ .x = 230, .y = 86, .w = 60, .h = 68 }, accent);

    surface.line(12, 180, bounds.w - 12, 200, accent);
    surface.line(12, 200, bounds.w - 12, 180, color_dim);

    if (body_font) |*font| {

        font.draw(surface, 12, bounds.h - 24, "click to recolor", color_dim);

    }

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
