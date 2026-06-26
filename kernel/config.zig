// Compile-time tunables (06-kernel-ddd.md Section 4).

pub const page_size: usize = 4096;

// Largest buddy block the frame allocator tracks: 2^frame_max_order pages (here 4 MiB).

pub const frame_max_order: usize = 10;
