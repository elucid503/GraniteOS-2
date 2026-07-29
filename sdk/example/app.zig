const granite = @import("granite");

const cap = granite.cap;
const events = granite.events;
const ui = granite.ui;

comptime {

    _ = granite.start;

}

var font: granite.draw.text.Face = undefined;
var connection: granite.window.Connection = undefined;
var window: granite.window.Window = undefined;

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    granite.prefs.refresh();

    if (args.len > 0) granite.wm.bind_program(args[0]);

    var bundle = try granite.desktop.open_bundle();

    font = try granite.desktop.ui_font(&bundle);
    connection = try granite.desktop.connect(cap.memory);
    window = try granite.wm.open_main(&connection, 420, 220, "Hello Granite");

    paint();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                granite.wm.close_main(&connection, &window);
                return;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                paint();

            },

            events.kind_prefs_changed => {

                _ = granite.prefs.apply_event(event);
                paint();

            },

            else => {},

        }

    }

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);
    const message = "Hello from a repository app.";
    const size: u32 = 18;
    const x = @divTrunc(width - font.text_width(message, size), 2);
    const y = @divTrunc(height - font.line_height(size), 2);

    surface.fill(ui.theme.window_bg);
    font.draw(surface, x, y, size, message, ui.theme.text);
    window.present_all() catch {};

}
