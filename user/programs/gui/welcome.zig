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

var inter: ?lib.draw.text.Face = null;

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

    inter = lib.draw.text.Face.parse(bundle.find("font-ttf") orelse return error.NotFound) catch return error.Invalid;

}

fn draw(surface: *const gfx.Surface) void {

    if (inter) |*font| {

        var page = ui.Page{ .font = font };

        page.begin(@intCast(surface.width), @intCast(surface.height), .{

            .direction = .column,
            .width = .{ .px = @intCast(surface.width) },
            .height = .{ .px = @intCast(surface.height) },
            .align_main = .center,
            .align_cross = .center,
            .gap = 24,
            .background = lib.prefs.wallpaper(),

        });

        _ = page.label(ui.Page.root, "GraniteOS 2", .{

            .size = 38,
            .color = ui.theme.text,

        });

        _ = page.label(ui.Page.root, "Click anywhere to continue", .{

            .size = 17,
            .color = ui.theme.text_dim,

        });

        page.end();
        page.paint(surface);

    }

}
