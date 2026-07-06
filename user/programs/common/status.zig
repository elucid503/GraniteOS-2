// status: compact system views over kernel inspect snapshots and filesystem disk info.

const std = @import("std");

const lib = @import("lib");

const sysinfo = lib.sysinfo;
const Stream = lib.stream.Stream;

comptime {

    _ = lib.start;

}

const queue_bar_width = 4;
const disk_bar_width = 58;
const repeat_buffer = 64;
const column_gap = 2;

const process_name_width = 12;
const process_id_width = 7;
const process_threads_width = 7;
const process_handles_width = 7;
const process_memory_width = 7;
const max_pie_entries = 5;
const pie_width: usize = 23;
const pie_height: usize = 11;
const pie_marks = "+*#@&o";
const process_regions_width = 7;
const process_endpoints_width = 9;
const process_notifs_width = 6;
const process_load_width = 10;

const Render = *const fn (*Stream) lib.io.Error!void;

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 2) {

        usage(out) catch {};
        return 1;

    }

    if (equals(args[1], "scheduler")) return view(out, render_scheduler);
    if (equals(args[1], "disk")) return view(out, render_disk);
    if (equals(args[1], "processes")) return view(out, render_processes);
    if (equals(args[1], "cpu")) return view(out, render_cpu);
    if (equals(args[1], "memory")) return view(out, render_memory);

    usage(out) catch {};
    return 1;

}

fn view(out: *Stream, render: Render) u8 {

    if (!lib.term.is_tty()) {

        render(out) catch return 1;
        return 0;

    }

    var input = lib.start.stdin() catch return 1;

    lib.term.set_raw(&input) catch return 1;
    defer lib.term.set_cooked(&input) catch {};

    refresh: while (true) {

        lib.term.clear_screen(out) catch return 1;
        render(out) catch return 1;
        lib.io.writeln(out, "") catch return 1;
        lib.io.write(out, "r refresh | q quit") catch return 1;

        while (true) {

            const key = lib.term.read_char(&input) catch return 1;

            if (key == 'q' or key == 'Q') break :refresh;
            if (key == 'r' or key == 'R') break;

        }

    }

    lib.io.writeln(out, "") catch return 1;

    return 0;

}

fn render_scheduler(out: *Stream) lib.io.Error!void {

    const snapshot = sysinfo.read(sysinfo.SchedulerSnapshot, .scheduler) catch return error.Invalid;
    const core_count: usize = @intCast(snapshot.core_count);
    const level_count: usize = @intCast(snapshot.level_count);

    try lib.io.print(out, "scheduler  {d}/{d} cores  boost {d}ms\n", .{
        snapshot.online_count,
        snapshot.core_count,
        snapshot.boost_interval_ns / 1_000_000,
    });

    try lib.io.write(out, "quantum   ");

    for (snapshot.quanta_ns[0..level_count], 0..) |quantum, level| {

        try lib.io.print(out, " level-{d}={d}ms", .{ level, quantum / 1_000_000 });

    }

    try lib.io.writeln(out, "");
    try lib.io.writeln(out, "");

    try write_cell(out, "core", 5);
    try write_gap(out);
    try write_cell(out, "state", 9);
    try write_gap(out);
    try write_cell(out, "process/thread", 17);
    try write_gap(out);
    try write_right_cell(out, "driver", 10);

    for (0..level_count) |level| {

        var label: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "level-{d}", .{level}) catch return error.Invalid;

        try write_gap(out);
        try write_right_cell(out, text, 10);

    }

    try lib.io.writeln(out, "");

    var index: usize = 0;

    while (index < core_count) : (index += 1) {

        const core = snapshot.cores[index];

        try write_u64_cell(out, @intCast(index), 5);
        try write_gap(out);
        try write_cell(out, if (core.online != 0) "online" else "offline", 9);
        try write_gap(out);
        try write_run_cell(out, core.current_pid, core.current_tid, 17);
        try write_gap(out);
        try write_load_cell(out, core.driver, 10);

        for (core.levels[0..level_count]) |count| {

            try write_gap(out);
            try write_load_cell(out, count, 10);

        }

        try lib.io.writeln(out, "");

    }

}

fn render_disk(out: *Stream) lib.io.Error!void {

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        try lib.io.writeln(out, "disk: filesystem unavailable");
        return;

    };

    const info = client.info() catch {

        try lib.io.writeln(out, "disk: information unavailable");
        return;

    };

    const total_mib = info.block_count * info.block_size / (1024 * 1024);
    const used_mib = info.used_blocks * info.block_size / (1024 * 1024);
    const free_mib = info.free_blocks * info.block_size / (1024 * 1024);

    try availability_bar(out, info.used_blocks, info.free_blocks, info.block_count);
    try lib.io.writeln(out, "");
    try lib.io.print(out, "{d} MiB  {d}B blocks  {d}B sectors\n", .{
        total_mib,
        info.block_size,
        info.sector_size,
    });

    try lib.io.writeln(out, "");
    try lib.io.print(out, "free       {d} MiB\n", .{free_mib});
    try lib.io.print(out, "used       {d} MiB\n", .{used_mib});
    try lib.io.writeln(out, "");
    try lib.io.print(out, "blocks    {d} total  {d} used  {d} available\n", .{
        info.block_count,
        info.used_blocks,
        info.free_blocks,
    });
    try lib.io.print(out, "layout    {d} sectors/block  {d} inodes\n", .{
        info.sectors_per_block,
        info.inode_count,
    });

}

fn render_processes(out: *Stream) lib.io.Error!void {

    const snapshot = sysinfo.read(sysinfo.ProcessSnapshot, .processes) catch {

        try lib.io.writeln(out, "processes: inspect unavailable");
        return;

    };

    try lib.io.print(out, "processes  {d}/{d} shown  threads {d}  handles {d}\n", .{
        @min(snapshot.count, snapshot.capacity),
        snapshot.count,
        snapshot.total_threads,
        snapshot.total_handles,
    });

    try lib.io.writeln(out, "");
    try write_cell(out, "", process_name_width);
    try write_gap(out);
    try write_right_cell(out, "process", process_id_width);
    try write_gap(out);
    try write_right_cell(out, "threads", process_threads_width);
    try write_gap(out);
    try write_right_cell(out, "handles", process_handles_width);
    try write_gap(out);
    try write_right_cell(out, "memory", process_memory_width);
    try write_gap(out);
    try write_right_cell(out, "regions", process_regions_width);
    try write_gap(out);
    try write_right_cell(out, "endpoints", process_endpoints_width);
    try write_gap(out);
    try write_right_cell(out, "notifs", process_notifs_width);
    try write_gap(out);
    try write_right_cell(out, "load", process_load_width);
    try lib.io.writeln(out, "");

    const shown: usize = @intCast(@min(snapshot.count, snapshot.capacity));
    var index: usize = 0;

    while (index < shown) : (index += 1) {

        const process = snapshot.processes[index];

        try write_name_cell(out, &process.name, process.name_len, process_name_width);
        try write_gap(out);
        try write_right_u64_cell(out, @intCast(process.pid), process_id_width);
        try write_gap(out);
        try write_right_u64_cell(out, @intCast(process.thread_count), process_threads_width);
        try write_gap(out);
        try write_right_u64_cell(out, @intCast(process.handle_count), process_handles_width);
        try write_gap(out);
        try write_memory_cell(out, process.memory_bytes, process_memory_width);
        try write_gap(out);
        try write_right_u64_cell(out, @intCast(process.handles_by_kind[3]), process_regions_width);
        try write_gap(out);
        try write_right_u64_cell(out, @intCast(process.handles_by_kind[4]), process_endpoints_width);
        try write_gap(out);
        try write_right_u64_cell(out, @intCast(process.handles_by_kind[5]), process_notifs_width);
        try write_gap(out);
        try write_load_cell(out, process.thread_count, process_load_width);
        try lib.io.writeln(out, "");

    }

}

fn render_memory(out: *Stream) lib.io.Error!void {

    const snapshot = sysinfo.read(sysinfo.MemorySnapshot, .memory) catch {

        try lib.io.writeln(out, "memory: inspect unavailable");
        return;

    };

    const used_frames = snapshot.total_frames - snapshot.free_frames;
    const page_size: u64 = snapshot.page_size;
    const total_mib = snapshot.total_frames * page_size / (1024 * 1024);
    const used_mib = used_frames * page_size / (1024 * 1024);
    const free_mib = snapshot.free_frames * page_size / (1024 * 1024);

    try availability_bar(out, used_frames, snapshot.free_frames, snapshot.total_frames);
    try lib.io.writeln(out, "");
    try lib.io.print(out, "{d} MiB  {d}B pages\n", .{ total_mib, page_size });

    try lib.io.writeln(out, "");
    try lib.io.print(out, "free       {d} MiB\n", .{free_mib});
    try lib.io.print(out, "used       {d} MiB\n", .{used_mib});
    try lib.io.writeln(out, "");
    try lib.io.print(out, "frames    {d} total  {d} used  {d} free\n", .{
        snapshot.total_frames,
        used_frames,
        snapshot.free_frames,
    });

    const processes = sysinfo.read(sysinfo.ProcessSnapshot, .processes) catch return;

    var entries: [max_pie_entries + 1]MemoryRank = undefined;
    var entry_count: usize = 0;

    rank_memory_processes(processes, &entries, &entry_count);

    try write_memory_pie(out, entries[0..entry_count]);

}

fn render_cpu(out: *Stream) lib.io.Error!void {

    const snapshot = sysinfo.read(sysinfo.CpuSnapshot, .cpu) catch {

        try lib.io.writeln(out, "cpu: inspect unavailable");
        return;

    };

    try lib.io.print(out, "cpu       {d}/{d} online  current core {d}\n", .{
        snapshot.online_count,
        snapshot.core_count,
        snapshot.current_core,
    });

    try lib.io.writeln(out, "");
    try write_cell(out, "core", 6);
    try write_gap(out);
    try write_cell(out, "state", 9);
    try write_gap(out);
    try write_cell(out, "process/thread", 17);
    try lib.io.writeln(out, "");

    const core_count: usize = @intCast(snapshot.core_count);
    var index: usize = 0;

    while (index < core_count) : (index += 1) {

        const core = snapshot.cores[index];

        try write_u64_cell(out, @intCast(core.id), 6);
        try write_gap(out);
        try write_cell(out, if (core.online != 0) "online" else "offline", 9);
        try write_gap(out);
        try write_run_cell(out, core.current_pid, core.current_tid, 17);
        try lib.io.writeln(out, "");

    }

}

fn usage(out: *Stream) lib.io.Error!void {

    try lib.io.writeln(out, "usage: status <scheduler|disk|processes|cpu|memory>");

}

fn availability_bar(out: *Stream, used: u64, available: u64, total: u64) lib.io.Error!void {

    const used_width: usize = @intCast(if (total == 0) 0 else @min(disk_bar_width, used * disk_bar_width / total));

    try lib.io.write(out, "[");
    try repeat(out, '#', used_width);
    try repeat(out, '.', disk_bar_width - used_width);
    try lib.io.print(out, "] {d}% available", .{if (total == 0) 0 else available * 100 / total});

}

fn write_load_cell(out: *Stream, value: u32, width: usize) lib.io.Error!void {

    const number_width = width - queue_bar_width;
    const filled = @min(queue_bar_width, @as(usize, @intCast(value)));

    try repeat(out, '#', filled);
    try repeat(out, '.', queue_bar_width - filled);
    try write_right_u64_cell(out, @intCast(value), number_width);

}

const MemoryRank = struct {

    value: u64,
    name: []const u8,

};

fn rank_memory_processes(snapshot: sysinfo.ProcessSnapshot, entries: *[max_pie_entries + 1]MemoryRank, count: *usize) void {

    const shown = @min(@as(usize, @intCast(@min(snapshot.count, snapshot.capacity))), sysinfo.max_processes);

    var ranked: [sysinfo.max_processes]MemoryRank = undefined;
    var ranked_len: usize = 0;

    for (0..shown) |index| {

        const process = snapshot.processes[index];

        if (process.memory_bytes == 0) continue;

        ranked[ranked_len] = .{
            .value = process.memory_bytes,
            .name = process.name[0..@min(@as(usize, @intCast(process.name_len)), process.name.len)],
        };

        ranked_len += 1;

    }

    var index: usize = 0;

    while (index < ranked_len) : (index += 1) {

        var next = index + 1;

        while (next < ranked_len) : (next += 1) {

            if (ranked[next].value > ranked[index].value) {

                const swap = ranked[index];
                ranked[index] = ranked[next];
                ranked[next] = swap;

            }

        }

    }

    count.* = 0;
    var other: u64 = 0;

    index = 0;

    while (index < ranked_len) : (index += 1) {

        if (index < max_pie_entries) {

            entries[count.*] = ranked[index];
            count.* += 1;

        } else {

            other += ranked[index].value;

        }

    }

    if (other > 0) {

        entries[count.*] = .{ .value = other, .name = "other" };
        count.* += 1;

    }

}

fn write_memory_pie(out: *Stream, entries: []const MemoryRank) lib.io.Error!void {

    if (entries.len == 0) return;

    var total: u64 = 0;

    for (entries) |entry| total += entry.value;

    if (total == 0) return;

    try lib.io.writeln(out, "");
    try lib.io.writeln(out, "by process");

    const center_x: i32 = @intCast(pie_width / 2);
    const center_y: i32 = @intCast(pie_height / 2);
    const radius: i32 = @intCast(@min(center_x, center_y));
    const radius_sq = radius * radius;

    var start: u16 = 0;
    var sweep_starts: [max_pie_entries + 1]u16 = undefined;
    var sweep_ends: [max_pie_entries + 1]u16 = undefined;

    for (entries, 0..) |entry, index| {

        sweep_starts[index] = start;

        const sweep: u16 = @intCast(@min(360, entry.value * 360 / total));

        start +%= sweep;
        sweep_ends[index] = start;

    }

    var row: usize = 0;

    while (row < pie_height) : (row += 1) {

        var col: usize = 0;

        while (col < pie_width) : (col += 1) {

            const dx = @as(i32, @intCast(col)) - center_x;
            const dy = @as(i32, @intCast(row)) - center_y;

            if (dx * dx + dy * dy > radius_sq) {

                try lib.io.write(out, " ");
                continue;

            }

            const angle = point_angle_cw(dx, dy);
            var mark: u8 = '.';

            for (entries, 0..) |_, index| {

                if (angle_in_wedge(angle, sweep_starts[index], sweep_ends[index])) {

                    mark = pie_marks[index % pie_marks.len];
                    break;

                }

            }

            try lib.io.write(out, &[_]u8{mark});

        }

        try lib.io.writeln(out, "");

    }

    for (entries, 0..) |entry, index| {

        const percent = if (total == 0) 0 else entry.value * 100 / total;

        try lib.io.print(out, "  {c} {s}  {d}%\n", .{ pie_marks[index % pie_marks.len], entry.name, percent });

    }

}

fn point_angle_cw(dx: i32, dy: i32) u16 {

    const rad = std.math.atan2(@as(f64, @floatFromInt(dx)), @as(f64, @floatFromInt(-dy)));

    var deg = rad * 180.0 / std.math.pi;

    if (deg < 0) deg += 360.0;

    return @intFromFloat(deg);

}

fn angle_in_wedge(angle: u16, start: u16, end: u16) bool {

    if (end <= 360) return angle >= start and angle < end;

    return angle >= start or angle < (end - 360);

}

fn write_memory_cell(out: *Stream, bytes: u64, width: usize) lib.io.Error!void {

    var buffer: [16]u8 = undefined;
    const mib = bytes / (1024 * 1024);
    const text = if (mib > 0)
        std.fmt.bufPrint(&buffer, "{d}M", .{mib}) catch return error.Invalid
    else
        std.fmt.bufPrint(&buffer, "{d}K", .{bytes / 1024}) catch return error.Invalid;

    try write_right_cell(out, text, width);

}

fn write_gap(out: *Stream) lib.io.Error!void {

    try repeat(out, ' ', column_gap);

}

fn write_run_cell(out: *Stream, pid: u32, tid: u32, width: usize) lib.io.Error!void {

    if (tid == 0) {

        try write_cell(out, "idle", width);
        return;

    }

    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}/{d}", .{ pid, tid }) catch return error.Invalid;

    try write_cell(out, text, width);

}

fn write_u64_cell(out: *Stream, value: u64, width: usize) lib.io.Error!void {

    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.Invalid;

    try write_cell(out, text, width);

}

fn write_right_u64_cell(out: *Stream, value: u64, width: usize) lib.io.Error!void {

    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.Invalid;
    var padding = text.len;

    while (padding < width) : (padding += 1) {

        try lib.io.write(out, " ");

    }

    try lib.io.write(out, text);

}

fn write_cell(out: *Stream, text: []const u8, width: usize) lib.io.Error!void {

    try lib.io.write(out, text);

    var padding = text.len;

    while (padding < width) : (padding += 1) {

        try lib.io.write(out, " ");

    }

}

fn write_right_cell(out: *Stream, text: []const u8, width: usize) lib.io.Error!void {

    var padding = text.len;

    while (padding < width) : (padding += 1) {

        try lib.io.write(out, " ");

    }

    try lib.io.write(out, text);

}

fn write_name_cell(out: *Stream, name: *const [sysinfo.process_name_bytes]u8, length: u32, width: usize) lib.io.Error!void {

    const limit = if (width == 0) 0 else width - 1;
    const amount = @min(@min(@as(usize, @intCast(length)), name.len), limit);

    if (amount == 0) {

        try write_cell(out, "-", width);
        return;

    }

    try write_cell(out, name[0..amount], width);

}


fn repeat(out: *Stream, byte: u8, count: usize) lib.io.Error!void {

    var index: usize = 0;
    var buffer: [repeat_buffer]u8 = undefined;

    while (index < count) : (index += 1) {

        buffer[index] = byte;

    }

    try lib.io.write(out, buffer[0..count]);

}

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}
