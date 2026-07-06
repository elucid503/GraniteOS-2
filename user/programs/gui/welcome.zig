// The M9 welcome screen: a fullscreen window with the system title and a click-to-continue prompt.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const ui = lib.ui;

var inter: ?lib.ttf.Face = null;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    try load_assets();

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

            lib.time.sleep_ms(5);

            continue;

        };

    }

}

fn load_assets() !void {

    const length: usize = @intCast(lib.start.word(3));
    const offset: usize = @intCast(lib.start.word(4));

    const base = try sys.map(cap.self_space, cap.gui.bundle, 0, sys.read);
    const bundle = try lib.bundle.Bundle.open(base + offset, length);

    inter = lib.ttf.Face.parse(bundle.find("font-ttf") orelse return error.NotFound) catch return error.Invalid;

}

fn draw(surface: *const gfx.Surface) void {

    const surface_rect = surface.bounds();
    const center_x = @divTrunc(surface_rect.w, 2);
    const center_y = @divTrunc(surface_rect.h, 2);

    surface.fill(lib.prefs.wallpaper());

    if (inter) |*font| {

        const title = "GraniteOS 2";
        const title_x = center_x - @divTrunc(font.text_width(title, 38), 2);
        const title_y = center_y - 38;

        font.draw(surface, title_x, title_y, 38, title, ui.theme.text);

        const subtitle = "Click anywhere to continue";
        const subtitle_x = center_x - @divTrunc(font.text_width(subtitle, 17), 2);
        const subtitle_y = center_y + 28;

        font.draw(surface, subtitle_x, subtitle_y, 17, subtitle, ui.theme.text_dim);

    }

}
