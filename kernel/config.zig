// Compile-time tunables (06-kernel-ddd.md Section 4).

pub const page_size: usize = 4096;

// Largest buddy block the frame allocator tracks: 2^frame_max_order pages (here 4 MiB).

pub const frame_max_order: usize = 10;

// Scheduling (06-kernel-ddd.md Section 10): MLFQ levels with growing quanta, plus the periodic anti-starvation boost.

pub const scheduling_levels: usize = 4;
pub const level_quanta_ns = [scheduling_levels]u64{ 5_000_000, 10_000_000, 20_000_000, 40_000_000 }; // 5, 10, 20, 40 ms
pub const boost_interval_ns: u64 = 1_000_000_000; // 1 second

// Upper bound for static per-core arrays; the actual count comes from the DTB.

pub const max_cores: usize = 64;

// Kernel stack size for every thread, in pages (16 KiB).

pub const thread_stack_pages: usize = 4;
