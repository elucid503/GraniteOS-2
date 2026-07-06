// Aggregates the host-testable pieces of the user runtime (the envelope layout, the device-tree reader, and the
// Strata on-disk format); anything that traps stays on the target.

test {

    _ = @import("lib");
    _ = @import("lib").gfx;
    _ = @import("lib").font;
    _ = @import("lib").ttf;
    _ = @import("lib").svg;
    _ = @import("lib").ui;
    _ = @import("lib").icons;
    _ = @import("lib").time;
    _ = @import("lib").events;
    _ = @import("lib").window;
    _ = @import("servers/naming/main.zig");
    _ = @import("servers/display/manager.zig");
    _ = @import("servers/filesystem/format.zig");

}
