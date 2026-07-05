// User-space mirror of the kernel inspect snapshots.

const sys = @import("syscall/sys.zig");

pub const max_cores: usize = 64;
pub const scheduling_levels: usize = 4;
pub const max_processes: usize = 32;
pub const object_kind_slots: usize = 11;
pub const process_name_bytes: usize = 24;

pub const Kind = enum(u64) {

    scheduler = 1,
    processes,
    cpu,

};

pub const QueueStats = extern struct {

    current_pid: u32,
    current_tid: u32,
    online: u32,
    driver: u32,

    levels: [scheduling_levels]u32,

};

pub const SchedulerSnapshot = extern struct {

    core_count: u32,
    online_count: u32,
    level_count: u32,
    reserved: u32,

    quanta_ns: [scheduling_levels]u64,
    boost_interval_ns: u64,

    cores: [max_cores]QueueStats,

};

pub const ProcessInfo = extern struct {

    pid: u32,
    name_len: u32,
    thread_count: u32,
    handle_count: u32,

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

    cores: [max_cores]CpuInfo,

};

pub fn read(comptime T: type, kind: Kind) sys.Error!T {

    var snapshot: T = undefined;

    _ = try sys.inspect(@intFromEnum(kind), @intFromPtr(&snapshot), @sizeOf(T));

    return snapshot;

}
