const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const draw = lib.draw;
const sys = lib.sys;

const Handle = cap.Handle;
const Rect = draw.Rect;
const Surface = draw.Surface;

// Multi-core scanout: helpers drain independent row bands while the compositor thread works the same
// queue. Window ordering stays on the compositor thread; only the back-buffer-to-scanout copy scales.

const max_helpers = 3;
const worker_stack_pages = 16;
const page_size = 4096;
const rows_per_unit: i32 = 8;
const min_parallel_pixels: u64 = 64 * 1024;

const Job = struct {

    live: u8 = 0,
    next: u32 = 0,
    limit: u32 = 0,
    finished: u32 = 0,

    dest: ?*const Surface = null,
    source: ?*const Surface = null,
    rect: Rect = Rect.empty,

};

const Helper = struct {

    wake: Handle = 0,
    thread: Handle = 0,

};

var job: Job = .{};
var helpers: [max_helpers]Helper = [_]Helper{.{}} ** max_helpers;
var helper_count: u32 = 0;
var helper_boot_id: u32 = 0;
var pool_started = false;

fn ensure_pool() void {

    if (pool_started) return;

    pool_started = true;

    const cores: u32 = @intCast(@max(@as(u64, 1), lib.start.word(lib.proto.init.core_count_word)));
    const want: u32 = @min(max_helpers, if (cores > 1) cores - 1 else 0);
    var index: u32 = 0;

    while (index < want) : (index += 1) {

        const wake = sys.create(.notification, 0, 0) catch break;
        const stack = sys.create(.region, worker_stack_pages * page_size, cap.memory) catch {

            sys.close(wake) catch {};
            break;

        };
        const base = sys.map(cap.self_space, stack, 0, sys.read | sys.write) catch {

            sys.close(stack) catch {};
            sys.close(wake) catch {};
            break;

        };
        const thread = sys.create_thread(@intFromPtr(&helper_entry), base + worker_stack_pages * page_size) catch {

            sys.unmap(cap.self_space, base) catch {};
            sys.close(stack) catch {};
            sys.close(wake) catch {};
            break;

        };

        helpers[helper_count] = .{ .wake = wake, .thread = thread };
        sys.start(thread) catch {

            helpers[helper_count] = .{};
            sys.close(thread) catch {};
            sys.unmap(cap.self_space, base) catch {};
            sys.close(stack) catch {};
            sys.close(wake) catch {};
            break;

        };

        sys.close(stack) catch {};
        helper_count += 1;

    }

}

fn helper_entry() callconv(.c) noreturn {

    const id = @atomicRmw(u32, &helper_boot_id, .Add, 1, .acq_rel);
    const wake = if (id < max_helpers) helpers[id].wake else 0;

    while (true) {

        _ = sys.wait(wake) catch sys.yield();

        if (@atomicLoad(u8, &job.live, .acquire) == 0) continue;

        drain_units();
        _ = @atomicRmw(u32, &job.finished, .Add, 1, .release);

    }

}

fn drain_units() void {

    while (true) {

        const index = @atomicRmw(u32, &job.next, .Add, 1, .acq_rel);

        if (index >= @atomicLoad(u32, &job.limit, .acquire)) return;

        copy_band(index);

    }

}

fn copy_band(index: u32) void {

    const destination = job.dest orelse return;
    const source = job.source orelse return;

    const y = job.rect.y + @as(i32, @intCast(index)) * rows_per_unit;
    const rows = @min(rows_per_unit, job.rect.y + job.rect.h - y);
    const band = Rect{ .x = job.rect.x, .y = y, .w = job.rect.w, .h = rows };

    destination.blit(band.x, band.y, source, band);

}

/// Copy a screen-space damage rectangle from the cached back buffer into scanout. Large bands share
/// the row work with the compositor helpers; small updates avoid the notification/barrier overhead.
pub fn blit_scanout(destination: *const Surface, source: *const Surface, rect: Rect) void {

    const visible = rect.intersect(destination.bounds()).intersect(source.bounds());

    if (visible.is_empty()) return;

    const pixels = @as(u64, @intCast(visible.w)) * @as(u64, @intCast(visible.h));

    if (pixels < min_parallel_pixels) {

        destination.blit(visible.x, visible.y, source, visible);
        return;

    }

    ensure_pool();

    if (helper_count == 0) {

        destination.blit(visible.x, visible.y, source, visible);
        return;

    }

    const rows: u32 = @intCast(visible.h);
    const units = (rows + @as(u32, @intCast(rows_per_unit)) - 1) / @as(u32, @intCast(rows_per_unit));

    job.dest = destination;
    job.source = source;
    job.rect = visible;

    @atomicStore(u32, &job.next, 0, .release);
    @atomicStore(u32, &job.limit, units, .release);
    @atomicStore(u32, &job.finished, 0, .release);
    @atomicStore(u8, &job.live, 1, .release);

    // Only wait on helpers that were actually signalled: a failed notify would otherwise never
    // increment `finished` and the barrier below would spin forever, freezing the compositor.

    var woken: u32 = 0;
    var helper: u32 = 0;

    while (helper < helper_count) : (helper += 1) {

        sys.notify(helpers[helper].wake, 1) catch continue;
        woken += 1;

    }

    drain_units();

    while (@atomicLoad(u32, &job.finished, .acquire) < woken) sys.yield();

    @atomicStore(u8, &job.live, 0, .release);

}

test "scanout job copies only its damage band" {

    var source_pixels = [_]draw.Color{

        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,

    };
    var destination_pixels = [_]draw.Color{0} ** source_pixels.len;
    const source = Surface.from_pixels(&source_pixels, 4, 4);
    const destination = Surface.from_pixels(&destination_pixels, 4, 4);

    job = .{

        .source = &source,
        .dest = &destination,
        .rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 },

    };
    defer job = .{};

    copy_band(0);

    try std.testing.expectEqualSlices(draw.Color, &.{

        0, 0,  0,  0,
        0, 6,  7,  0,
        0, 10, 11, 0,
        0, 0,  0,  0,

    }, &destination_pixels);

}
