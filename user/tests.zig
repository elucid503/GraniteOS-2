// Host-testable user runtime pieces; target-only code stays off the host.

test {

    _ = @import("lib");
    _ = @import("lib").draw;
    _ = @import("lib").draw.bitmap;
    _ = @import("lib").draw.image;
    _ = @import("lib").draw.path;
    _ = @import("lib").draw.png;
    _ = @import("lib").draw.raster;
    _ = @import("lib").draw.round;
    _ = @import("lib").draw.stroke;
    _ = @import("lib").draw.text;
    _ = @import("lib").draw.vector;
    _ = @import("lib").ui;
    _ = @import("lib").ui.chart;
    _ = @import("lib").icons;
    _ = @import("lib").time;
    _ = @import("lib").localtime;
    _ = @import("lib").events;
    _ = @import("lib").window;
    _ = @import("lib").rng;
    _ = @import("lib").url;
    _ = @import("lib").tls;
    _ = @import("servers/naming/main.zig");
    _ = @import("servers/display/manager.zig");
    _ = @import("servers/display/render.zig");
    _ = @import("servers/display/parallel.zig");
    _ = @import("servers/display/surfaces.zig");
    _ = @import("servers/filesystem/format.zig");

}
