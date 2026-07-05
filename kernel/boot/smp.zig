// Secondary-core bring-up (06-kernel-ddd.md Section 16.2): give every DTB-discovered core a boot stack, PSCI-start
// it at the arch's secondary entry, and wait for it to register with the scheduler. No fixed core count anywhere -
// whatever the tree lists (up to config.max_cores) comes up.

const std = @import("std");

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const frames = @import("../memory/frames.zig");
const scheduler = @import("../sched/scheduler.zig");
const dtb = @import("dtb.zig");

const types = @import("../types.zig");

const boot_stack_pages = config.thread_stack_pages;

// A core's aff0 doubles as its scheduler index on this class of machine.

const core_id_mask: u64 = 0xff;

// Generous next to real bring-up time (well under a millisecond), so a wedged core cannot stall boot.

const online_timeout_ns: u64 = 500_000_000;

var records: [config.max_cores]types.BootRecord = undefined;

/// Start every secondary the DTB lists; returns the number of cores online afterwards.
pub fn start(machine: dtb.Machine) usize {

    const method = machine.power orelse return scheduler.online_count();

    for (machine.cpus) |mpidr| {

        const core_id: u64 = mpidr & core_id_mask;

        if (core_id == arch.core_id()) continue;
        if (core_id >= config.max_cores) continue;

        start_one(method, mpidr, @intCast(core_id));

    }

    return scheduler.online_count();

}

fn start_one(method: types.PowerMethod, mpidr: u64, core_id: u32) void {

    const stack = frames.alloc_contiguous(boot_stack_pages) catch return;

    records[core_id] = .{

        .stack_top = stack + boot_stack_pages * config.page_size,
        .core_id = core_id,

    };

    // The secondary reads its record with the MMU and caches off, so push it to RAM first.

    arch.clean_invalidate_data_cache(@intFromPtr(&records[core_id]), @sizeOf(types.BootRecord));

    arch.start_core(method, mpidr, &records[core_id]) catch {

        frames.free_contiguous(stack, boot_stack_pages);
        return;

    };

    wait_online(core_id);

}

fn wait_online(core_id: u32) void {

    const deadline = arch.now_ns() + online_timeout_ns;

    while (arch.now_ns() < deadline) {

        if (scheduler.core_is_online(core_id)) return;

        std.atomic.spinLoopHint();

    }

}
