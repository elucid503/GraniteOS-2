// Aggregates the host-testable pieces of the user runtime (the envelope layout, the device-tree reader, and the
// Strata on-disk format); anything that traps stays on the target.

test {

    _ = @import("lib");
    _ = @import("lib").draw;
    _ = @import("lib").draw.bitmap;
    _ = @import("lib").draw.path;
    _ = @import("lib").draw.raster;
    _ = @import("lib").draw.stroke;
    _ = @import("lib").draw.text;
    _ = @import("lib").draw.vector;
    _ = @import("lib").ui;
    _ = @import("lib").ui.chart;
    _ = @import("lib").icons;
    _ = @import("lib").time;
    _ = @import("lib").events;
    _ = @import("lib").window;
    _ = @import("servers/naming/main.zig");
    _ = @import("servers/display/manager.zig");
    _ = @import("servers/display/render.zig");
    _ = @import("servers/display/surfaces.zig");
    _ = @import("servers/filesystem/format.zig");

}
