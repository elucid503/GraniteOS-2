// A small welcome window used as the minimal GUI smoke test.

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const color_backdrop = gfx.rgb(56, 56, 56);
const color_title = gfx.rgb(240, 240, 240);
const color_body = gfx.rgb(176, 176, 176);

var inter: ?lib.ttf.Face = null;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try load_assets();

    var connection = try connect();
    var window = try connection.create_window(360, 150, 0, "Welcome");

    draw(&window.surface);
    gfx.fence();
    try window.present_all();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return;

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

fn load_assets() !void {

    const length: usize = @intCast(lib.start.word(3));
    const offset: usize = @intCast(lib.start.word(4));

    const base = try sys.map(cap.self_space, cap.gui.bundle, 0, sys.read);
    const bundle = try lib.bundle.Bundle.open(base + offset, length);

    inter = lib.ttf.Face.parse(bundle.find("font-ttf") orelse return error.NotFound) catch return error.Invalid;

}

fn draw(surface: *const gfx.Surface) void {

    surface.fill(color_backdrop);

    if (inter) |*font| {

        const title = "Welcome";
        const body = "GraniteOS is ready.";

        font.draw(surface, 24, 26, 28, title, color_title);
        font.draw(surface, 26, 82, 16, body, color_body);

    }

}
