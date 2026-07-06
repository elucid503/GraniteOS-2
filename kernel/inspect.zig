// Fixed-layout snapshots copied to user space by the read-only inspect syscall.

const config = @import("config.zig");
const frames = @import("memory/frames.zig");

pub const max_processes: usize = 32;
pub const object_kind_slots: usize = 11;
pub const process_name_bytes: usize = 24;

pub const Kind = enum(u64) {

    scheduler = 1,
    processes,
    cpu,
    memory,

};

pub const QueueStats = extern struct {

    current_pid: u32,
    current_tid: u32,
    online: u32,
    driver: u32,

    levels: [config.scheduling_levels]u32,

};

pub const LevelQueueStats = extern struct {

    count: u32,
    lead_pid: u32,
    lead_tid: u32,

};

pub const SchedulerSnapshot = extern struct {

    core_count: u32,
    online_count: u32,
    level_count: u32,
    reserved: u32,

    quanta_ns: [config.scheduling_levels]u64,
    boost_interval_ns: u64,

    level_queues: [config.scheduling_levels]LevelQueueStats,

    cores: [config.max_cores]QueueStats,

};

pub const ProcessInfo = extern struct {

    pid: u32,
    name_len: u32,
    thread_count: u32,
    handle_count: u32,

    memory_bytes: u64,

    name: [process_name_bytes]u8,
    handles_by_kind: [object_kind_slots]u32,

};

pub const ProcessSnapshot = extern struct {

    count: u32,
    capacity: u32,
    total_threads: u32,
    total_handles: u32,

    processes: [max_processes]ProcessInfo,

};

pub const CpuInfo = extern struct {

    id: u32,
    online: u32,
    current_pid: u32,
    current_tid: u32,

};

pub const CpuSnapshot = extern struct {

    core_count: u32,
    online_count: u32,
    current_core: u32,
    max_cores: u32,

    cores: [config.max_cores]CpuInfo,

};

pub const MemorySnapshot = extern struct {

    page_size: u32,
    reserved: u32,

    total_frames: u64,
    free_frames: u64,

};

pub fn memory_snapshot(out: *MemorySnapshot) void {

    const counts = frames.stats();

    out.* = .{

        .page_size = @intCast(config.page_size),
        .reserved = 0,

        .total_frames = @intCast(counts.total),
        .free_frames = @intCast(counts.free),

    };

}
