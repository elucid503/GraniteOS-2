// Aggregates the host-testable pieces of the user runtime (the envelope layout, the device-tree reader, and the
// Strata on-disk format); anything that traps stays on the target.

test {

    _ = @import("lib");
    _ = @import("servers/naming/main.zig");
    _ = @import("servers/filesystem/format.zig");

}
