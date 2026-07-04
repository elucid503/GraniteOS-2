// Aggregates the host-testable pieces of the user runtime (the envelope layout and the device-tree reader); anything that traps stays on the target.

test {

    _ = @import("lib/ipc.zig");
    _ = @import("lib/dtb.zig");

}
