// Aggregates the host-testable core (allocators, parsers) so `zig build test` exercises it on the host, off the arch path.

test {

    _ = @import("memory/frames.zig");
    _ = @import("memory/slab.zig");
    _ = @import("memory/region.zig");
    _ = @import("object/object.zig");
    _ = @import("boot/dtb.zig");
    _ = @import("cap/handle.zig");
    _ = @import("cap/handle_table.zig");
    _ = @import("sched/runqueue.zig");
    _ = @import("sched/scheduler.zig");

}
