// MLFQ per-core scheduler: driver band, quanta, boost, work-stealing, and IPC donation; queue locks guard stealers.

const builtin = @import("builtin");
const std = @import("std");

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const inspect = @import("../inspect.zig");
const object = @import("../object/object.zig");
const runqueue = @import("runqueue.zig");
const spinlock = @import("../sync/spinlock.zig");

const thread_module = @import("../object/thread.zig");

const Thread = thread_module.Thread;
const RunQueue = runqueue.RunQueue;

const PhysAddr = arch.PhysAddr;

pub const Class = enum(u8) {

    driver,
    normal,

};

pub const SchedulingState = struct {

    class: Class = .normal,
    level: u8 = 0,
    quantum_remaining_ns: u64 = 0,
    last_started_ns: u64 = 0,

};

pub const Core = struct {

    id: u32,
    current: ?*Thread,

    driver_queue: RunQueue,
    levels: [config.scheduling_levels]RunQueue,

    idle_context: arch.Context,
    last_boost_ns: u64,

    // The full TTBR0 value (root ORed with ASID) currently loaded, so a switch within one space skips the reload.
    space_root: u64,

    // The ASID generation this core last flushed for; a rollover forces one local full flush on the next switch.
    asid_generation_seen: u64,

    // A thread that exited on this core; freed by the next thread once it is off the dead thread's stack.
    zombie: ?*Thread,

    // Guards the two queue sets above; taken by this core and by peers stealing from it.
    lock: spinlock.SpinLock,

    // The thread being switched away from; whoever runs next on this core publishes its saved context.
    outgoing: ?*Thread,

    // Deadline-sorted sleepers; touched only by this core with IRQs off, so no lock.
    sleepers: ?*Thread,

    online: bool,

};

const bottom_level = config.scheduling_levels - 1;

// Shortest idle tick when peers still have queued work (stealing stays responsive). Otherwise sleep until the next boost.

const idle_steal_ns = config.level_quanta_ns[0];

var cores: [config.max_cores]Core = undefined;
var core_count: usize = 1;
var admit_cursor: usize = 0;

pub fn init(count: usize) void {

    core_count = @max(1, @min(count, config.max_cores));

    for (cores[0..core_count], 0..) |*core, index| {

        core.* = .{

            .id = @intCast(index),
            .current = null,

            .driver_queue = .{},
            .levels = [_]RunQueue{.{}} ** config.scheduling_levels,

            // Zeroed (not undefined) so the first switch away from idle reads a defined `used_fp` (0) in switch.S.
            .idle_context = std.mem.zeroes(arch.Context),
            .last_boost_ns = arch.now_ns(),

            .space_root = 0,
            .asid_generation_seen = 0,
            .zombie = null,

            .lock = .{},
            .outgoing = null,

            .sleepers = null,

            .online = index == 0,

        };

    }

}

/// Secondary cores join here (their first act in `main_secondary`); admission and stealing include them from now on.
pub fn register_core(core_id: u32) void {

    cores[core_id].last_boost_ns = arch.now_ns();

    @atomicStore(bool, &cores[core_id].online, true, .release);

}

pub fn core_is_online(core_id: u32) bool {

    return @atomicLoad(bool, &cores[core_id].online, .acquire);

}

pub fn online_count() usize {

    var count: usize = 0;

    for (cores[0..core_count]) |*core| {

        if (@atomicLoad(bool, &core.online, .acquire)) count += 1;

    }

    return count;

}

pub fn scheduler_snapshot(out: *inspect.SchedulerSnapshot) void {

    out.* = .{

        .core_count = @intCast(core_count),
        .online_count = @intCast(online_count()),
        .level_count = @intCast(config.scheduling_levels),
        .reserved = 0,

        .quanta_ns = config.level_quanta_ns,
        .boost_interval_ns = config.boost_interval_ns,

        .level_queues = [_]inspect.LevelQueueStats{empty_level_queue_stats()} ** config.scheduling_levels,
        .cores = [_]inspect.QueueStats{empty_queue_stats()} ** config.max_cores,

    };

    for (cores[0..core_count], 0..) |*core, index| {

        core.lock.lock();

        var stats = empty_queue_stats();
        stats.online = @intFromBool(@atomicLoad(bool, &core.online, .acquire));
        stats.driver = core.driver_queue.count();

        if (core.current) |thread| {

            stats.current_pid = thread.process.pid;
            stats.current_tid = thread.id;

        }

        for (&core.levels, 0..) |*level, level_index| {

            const depth = level.count();

            stats.levels[level_index] = depth;
            out.level_queues[level_index].count += depth;

            if (out.level_queues[level_index].lead_tid == 0) {

                if (level.head) |thread| {

                    out.level_queues[level_index].lead_pid = thread.process.pid;
                    out.level_queues[level_index].lead_tid = thread.id;

                }

            }

        }

        if (core.current) |thread| {

            if (thread.scheduling.class == .normal) {

                const level_index: usize = thread.scheduling.level;

                out.level_queues[level_index].count += 1;

                if (out.level_queues[level_index].lead_tid == 0) {

                    out.level_queues[level_index].lead_pid = thread.process.pid;
                    out.level_queues[level_index].lead_tid = thread.id;

                }

            }

        }

        core.lock.unlock();

        out.cores[index] = stats;

    }

}

pub fn cpu_snapshot(out: *inspect.CpuSnapshot) void {

    out.* = .{

        .core_count = @intCast(core_count),
        .online_count = @intCast(online_count()),
        .current_core = arch.core_id(),
        .max_cores = @intCast(config.max_cores),

        .cores = [_]inspect.CpuInfo{empty_cpu_info()} ** config.max_cores,

    };

    for (cores[0..core_count], 0..) |*core, index| {

        var info = inspect.CpuInfo{

            .id = core.id,
            .online = @intFromBool(@atomicLoad(bool, &core.online, .acquire)),
            .current_pid = 0,
            .current_tid = 0,

        };

        if (core.current) |thread| {

            info.current_pid = thread.process.pid;
            info.current_tid = thread.id;

        }

        out.cores[index] = info;

    }

}

fn empty_level_queue_stats() inspect.LevelQueueStats {

    return .{

        .count = 0,
        .lead_pid = 0,
        .lead_tid = 0,

    };

}

fn empty_queue_stats() inspect.QueueStats {

    return .{

        .current_pid = 0,
        .current_tid = 0,
        .online = 0,
        .driver = 0,

        .levels = [_]u32{0} ** config.scheduling_levels,

    };

}

fn empty_cpu_info() inspect.CpuInfo {

    return .{

        .id = 0,
        .online = 0,
        .current_pid = 0,
        .current_tid = 0,

    };

}

pub fn current_core() *Core {

    return &cores[arch.core_id()];

}

/// Admit a fresh thread, round-robin across the online cores; a remote landing gets a reschedule IPI.
pub fn admit(thread: *Thread) void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const target = next_admit_core();

    enqueue(target, thread);

    if (target != current_core()) arch.send_ipi(target.id, .reschedule);

}

fn next_admit_core() *Core {

    var cursor = @atomicRmw(usize, &admit_cursor, .Add, 1, .monotonic);

    for (0..core_count) |_| {

        const core = &cores[cursor % core_count];
        cursor += 1;

        if (@atomicLoad(bool, &core.online, .acquire)) return core;

    }

    return current_core();

}

/// Timer policy: charge quanta, demote, boost, return next runnable (or null); no switch.
pub fn on_tick(core: *Core, now_ns: u64) ?*Thread {

    wake_sleepers(core, now_ns);
    boost(core, now_ns);

    if (core.current) |current| {

        const elapsed = now_ns - current.scheduling.last_started_ns;

        if (elapsed >= current.scheduling.quantum_remaining_ns) {

            demote(current);
            defer_dispatch(current);
            enqueue(core, current);
            core.current = null;

        } else {

            current.scheduling.quantum_remaining_ns -= elapsed;
            current.scheduling.last_started_ns = now_ns;

        }

    }

    // The driver band is strict priority: a waiting driver preempts any normal thread.

    if (core.current) |current| {

        if (current.scheduling.class == .normal and !core.driver_queue.is_empty()) {

            defer_dispatch(current);
            enqueue(core, current);
            core.current = null;

        }

    }

    if (core.current) |current| return current;

    return pick_next(core);

}

pub fn pick_next(core: *Core) ?*Thread {

    if (pop_local(core)) |thread| return thread;

    return steal_from_peers(core);

}

fn pop_local(core: *Core) ?*Thread {

    core.lock.lock();
    defer core.lock.unlock();

    if (core.driver_queue.pop()) |thread| return thread;

    for (&core.levels) |*level| {

        if (level.pop()) |thread| return thread;

    }

    return null;

}

// Steal from the next online peer with queued work; one runqueue lock at a time avoids deadlock.

fn steal_from_peers(core: *Core) ?*Thread {

    if (core_count == 1) return null;

    for (1..core_count) |offset| {

        const peer = &cores[(core.id + offset) % core_count];

        if (!@atomicLoad(bool, &peer.online, .acquire)) continue;

        peer.lock.lock();

        const stolen = blk: {

            for (&peer.levels) |*level| {

                if (level.pop()) |thread| break :blk thread;

            }

            break :blk null;

        };

        peer.lock.unlock();

        if (stolen) |thread| return thread;

    }

    return null;

}

/// Mark `thread` as this core's running thread and start its accounting window.
pub fn dispatch(core: *Core, thread: *Thread, now_ns: u64) void {

    if (thread.scheduling.quantum_remaining_ns == 0) {

        thread.scheduling.quantum_remaining_ns = quantum_of(thread);

    }

    thread.scheduling.last_started_ns = now_ns;
    thread.state = .running;
    core.current = thread;

}

/// Device IRQ path: only driver-band preemption, not a full MLFQ tick; idle cores pick up newly runnable drivers.
pub fn driver_preempt() void {

    // Runs only from the device-IRQ path, where interrupts are already masked (like `tick`).

    const core = current_core();
    const now = arch.now_ns();

    if (core.current) |current| {

        if (current.scheduling.class == .normal and !core.driver_queue.is_empty()) {

            defer_dispatch(current);
            enqueue(core, current);
            core.current = null;

            reschedule(core, current, pick_next(core), now, .pending);

        }

        return;

    }

    if (pick_next(core)) |next| {

        reschedule(core, null, next, now, .pending);

    }

}

/// The IRQ-path tick: run the policy, then re-arm the deadline and switch if the choice changed.
pub fn tick() void {

    const core = current_core();
    const now = arch.now_ns();

    const previous = core.current;
    const next = on_tick(core, now);

    reschedule(core, previous, next, now, .consumed);

}

/// Syscall `yield`: give up the rest of this quantum but keep the level.
pub fn yield() void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = current_core();
    const current = core.current orelse return;
    const now = arch.now_ns();

    defer_dispatch(current);
    enqueue(core, current);
    core.current = null;

    reschedule(core, current, pick_next(core), now, .pending);

}

/// Park until `now + ns` on this core's sleeper list; `on_tick` drains it so user code can wait without spinning.
pub fn sleep(ns: u64) void {

    if (ns == 0) return yield();

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = current_core();
    const current = core.current orelse return;
    const now = arch.now_ns();

    current.wake_at_ns = now + ns;
    current.state = .blocked_sleep;

    defer_dispatch(current);

    insert_sleeper(core, current);

    core.current = null;

    reschedule(core, current, pick_next(core), now, .pending);

}

// Deadline-sorted sleepers: expiry pops from the front; insert is O(n) in the small sleeper count.

fn insert_sleeper(core: *Core, thread: *Thread) void {

    var link = &core.sleepers;

    while (link.*) |existing| {

        if (existing.wake_at_ns > thread.wake_at_ns) break;

        link = &existing.sleep_next;

    }

    thread.sleep_next = link.*;
    link.* = thread;

}

// Drain expired sleepers at the top of `on_tick` so they are immediately pickable.

fn wake_sleepers(core: *Core, now_ns: u64) void {

    // Sorted ascending, so once the head is still in the future every later sleeper is too.

    while (core.sleepers) |thread| {

        if (thread.wake_at_ns > now_ns) break;

        core.sleepers = thread.sleep_next;
        thread.sleep_next = null;

        enqueue(core, thread);

    }

}

// Soonest sleeper deadline (the sorted list head) for idle-core timer arming.

fn earliest_sleeper(core: *Core) ?u64 {

    if (core.sleepers) |head| return head.wake_at_ns;

    return null;

}

/// Park after caller blocked and deferred dispatch; blocking before quantum expiry keeps the MLFQ level.
pub fn block(core: *Core, thread: *Thread) void {

    if (core.current != thread) return;

    core.current = null;

    reschedule(core, thread, pick_next(core), arch.now_ns(), .pending);

}

/// Wake on the waker's core for cache warmth; wait-object lock serializes competing wakers.
pub fn unblock(waker: *Core, thread: *Thread) void {

    thread.blocked_on = null;

    enqueue(waker, thread);

    // Busy waker core: poke an idle peer to steal normal threads now; driver wakeups preempt locally instead.

    if (thread.scheduling.class == .normal) poke_idle_peer(waker);

}

// Reschedule IPI to one idle peer; unlocked current==null heuristic may spuriously wake but stays correct.

fn poke_idle_peer(waker: *Core) void {

    if (core_count == 1) return;

    for (1..core_count) |offset| {

        const peer = &cores[(waker.id + offset) % core_count];

        if (!@atomicLoad(bool, &peer.online, .acquire)) continue;
        if (@atomicLoad(?*Thread, &peer.current, .monotonic) != null) continue;

        arch.send_ipi(peer.id, .reschedule);
        return;

    }

}

/// Wake a thread blocked in send/call because its peer died (06-kernel-ddd.md Section 9): its syscall unwinds as `Gone`.
pub fn abort_ipc(thread: *Thread) void {

    thread.ipc_aborted = true;
    thread.awaiting_reply = false;

    unblock(current_core(), thread);

}

/// IPC hand-off: switch `from` to waiting `to` on this core without a run-queue trip.
pub fn hand_off(from: *Thread, to: *Thread) void {

    const core = current_core();

    core.current = null;

    reschedule(core, from, to, arch.now_ns(), .pending);

}

/// Reply hand-back: enqueue server, resume caller immediately on restored scheduling.
pub fn hand_back(server: *Thread, caller: *Thread) void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = current_core();

    defer_dispatch(server);
    enqueue(core, server);
    core.current = null;

    reschedule(core, server, caller, arch.now_ns(), .pending);

}

/// Donate caller scheduling to server until reply; only raises priority, never demotes a driver-class server.
pub fn donate(from: *Thread, to: *Thread) void {

    if (to.donated_scheduling != null) return;
    if (!outranks(&from.scheduling, &to.scheduling)) return;

    to.donated_scheduling = to.scheduling;
    to.scheduling = from.scheduling;
    to.scheduling.last_started_ns = arch.now_ns();

}

fn outranks(a: *const SchedulingState, b: *const SchedulingState) bool {

    if (a.class != b.class) return a.class == .driver;

    return a.level < b.level;

}

/// At reply, caller takes back depleted scheduling and server restores its own.
pub fn settle_donation(server: *Thread, caller: *Thread) void {

    const own = server.donated_scheduling orelse return;

    caller.scheduling = server.scheduling;
    server.scheduling = own;
    server.donated_scheduling = null;

}

/// Mark context stale before enqueue so stealers wait for the wake-before-save handshake.
pub fn defer_dispatch(thread: *Thread) void {

    @atomicStore(bool, &thread.context_saved, false, .monotonic);

}

fn wait_context_saved(thread: *Thread) void {

    while (!@atomicLoad(bool, &thread.context_saved, .acquire)) {

        arch.wait_for_event();

    }

}

/// Drop running thread's refcount; zombie reaped after switch off its stack.
pub fn exit_current() noreturn {

    _ = arch.disable_interrupts();

    const core = current_core();
    const current = core.current.?;

    // Fault-aware teardown (06-kernel-ddd.md Section 9): wake anyone this thread owed a reply or blocked toward.

    current.release_ipc();

    current.state = .dead;
    core.current = null;

    if (current.header.release()) core.zombie = current;

    reschedule(core, current, pick_next(core), arch.now_ns(), .pending);

    unreachable;

}

// Reap zombie only after switching off the exited thread's stack.

fn reap(core: *Core) void {

    if (core.zombie) |zombie| {

        core.zombie = null;
        object.destroy(&zombie.header);

    }

}

// After switch: publish outgoing context for `wait_context_saved` and reap any zombie.

fn after_switch(core: *Core) void {

    if (core.outgoing) |previous| {

        core.outgoing = null;

        @atomicStore(bool, &previous.context_saved, true, .release);
        arch.send_event();

    }

    reap(core);

}

// The trampoline in `asm/switch.S` calls this the instant a freshly-scheduled thread lands.

export fn kernel_after_switch() callconv(.c) void {

    after_switch(current_core());

}

// The trampoline in `asm/switch.S` lands here when a kernel thread's entry function returns.

export fn kernel_thread_return() callconv(.c) noreturn {

    exit_current();

}

fn peer_has_queued_work(core: *Core) bool {

    for (cores[0..core_count]) |*peer| {

        if (peer.id == core.id) continue;
        if (!@atomicLoad(bool, &peer.online, .acquire)) continue;

        peer.lock.lock();

        const found = blk: {

            if (!peer.driver_queue.is_empty()) break :blk true;

            for (&peer.levels) |*level| {

                if (!level.is_empty()) break :blk true;

            }

            break :blk false;

        };

        peer.lock.unlock();

        if (found) return true;

    }

    return false;

}

fn core_has_queued_work(core: *Core) bool {

    core.lock.lock();
    defer core.lock.unlock();

    if (!core.driver_queue.is_empty()) return true;

    for (&core.levels) |*level| {

        if (!level.is_empty()) return true;

    }

    return false;

}

fn system_has_runnable_work() bool {

    for (cores[0..core_count]) |*core| {

        if (!@atomicLoad(bool, &core.online, .acquire)) continue;

        if (core.current != null) return true;
        if (core_has_queued_work(core)) return true;

    }

    return false;

}

fn idle_deadline(core: *Core, now_ns: u64) u64 {

    if (peer_has_queued_work(core)) return idle_steal_ns;

    const elapsed = now_ns - core.last_boost_ns;

    if (elapsed >= config.boost_interval_ns) return idle_steal_ns;

    return config.boost_interval_ns - elapsed;

}

// The minimum a sleep deadline is armed to, so an already-expired sleeper fires promptly rather than arming zero.
const min_sleep_arm_ns: u64 = 50_000;

fn arm_idle_timer(core: *Core, now_ns: u64) void {

    const sleeper_delay = if (earliest_sleeper(core)) |at|
        @max(min_sleep_arm_ns, if (at > now_ns) at - now_ns else 0)
    else
        null;

    if (system_has_runnable_work()) {

        const deadline = idle_deadline(core, now_ns);

        arch.arm_deadline(if (sleeper_delay) |delay| @min(deadline, delay) else deadline);

    } else if (sleeper_delay) |delay| {

        arch.arm_deadline(delay);

    } else {

        arch.disarm_deadline();

    }

}

/// A core's hand-off into scheduling (the primary after boot, secondaries after registering): the idle path.
pub fn idle() noreturn {

    arm_idle_timer(current_core(), arch.now_ns());
    arch.enable_interrupts();

    while (true) {

        arch.wait_for_interrupt();

    }

}

// Pending deadline must survive same-thread reschedules or tight yield loops would never tick/boost.

const Deadline = enum {

    consumed,
    pending,

};

// Re-arm deadline and switch with IRQs off; preempted threads resume here and re-read current core after switch.

fn reschedule(core: *Core, previous: ?*Thread, next: ?*Thread, now_ns: u64, deadline: Deadline) void {

    if (next) |thread| {

        if (thread == previous) {

            // Re-picked without leaving the core: its live context was never stale.

            @atomicStore(bool, &thread.context_saved, true, .release);
            arch.send_event();

        } else {

            wait_context_saved(thread);

        }

        dispatch(core, thread, now_ns);

        if (thread != previous or deadline == .consumed) {

            arch.arm_deadline(thread.scheduling.quantum_remaining_ns);

        }

        if (thread != previous) {

            activate_space(core, thread);

            const save_into = if (previous) |p| &p.context else &core.idle_context;

            core.outgoing = previous;
            arch.switch_context(save_into, &thread.context);
            after_switch(current_core());

        }

    } else {

        arm_idle_timer(core, now_ns);

        if (previous) |p| {

            core.outgoing = p;
            arch.switch_context(&p.context, &core.idle_context);
            after_switch(current_core());

        }

    }

}

// Reload TTBR0 when space changes; shared kernel slot keeps EL1 mappings live; compiled out in host tests.

fn activate_space(core: *Core, thread: *Thread) void {

    if (builtin.is_test) return;

    const space = thread.process.address_space;
    const ttbr = space.ttbr();

    if (ttbr == core.space_root) return;

    // One local full flush per ASID generation before adopting a new space after rollover.

    const generation = arch.asid_generation();

    if (generation != core.asid_generation_seen) {

        arch.tlb_flush_local();
        core.asid_generation_seen = generation;

    }

    core.space_root = ttbr;
    arch.activate_space(ttbr);

}

fn enqueue(core: *Core, thread: *Thread) void {

    thread.state = .ready;
    thread.scheduling.quantum_remaining_ns = quantum_of(thread);

    core.lock.lock();
    defer core.lock.unlock();

    if (thread.scheduling.class == .driver) {

        core.driver_queue.push(thread);

    } else {

        core.levels[thread.scheduling.level].push(thread);

    }

}

fn demote(thread: *Thread) void {

    if (thread.scheduling.class != .normal) return;

    if (thread.scheduling.level < bottom_level) thread.scheduling.level += 1;

}

// Anti-starvation aging: every boost interval, all normal threads on this core return to level 0.

fn boost(core: *Core, now_ns: u64) void {

    if (now_ns - core.last_boost_ns < config.boost_interval_ns) return;

    core.last_boost_ns = now_ns;

    core.lock.lock();

    for (core.levels[1..]) |*level| {

        while (level.pop()) |thread| {

            thread.scheduling.level = 0;
            thread.scheduling.quantum_remaining_ns = config.level_quanta_ns[0];
            core.levels[0].push(thread);

        }

    }

    core.lock.unlock();

    if (core.current) |current| {

        if (current.scheduling.class == .normal) current.scheduling.level = 0;

    }

}

fn quantum_of(thread: *const Thread) u64 {

    if (thread.scheduling.class == .driver) return config.level_quanta_ns[0];

    return config.level_quanta_ns[thread.scheduling.level];

}

const testing = @import("std").testing;

fn test_thread() Thread {

    var thread: Thread = undefined;

    thread.state = .ready;
    thread.scheduling = .{};
    thread.donated_scheduling = null;
    thread.queue_link = .{};
    thread.blocked_on = null;
    thread.context_saved = true;

    return thread;

}

test "a spinning thread demotes one level per exhausted quantum" {

    init(1);

    const core = current_core();

    var spinner = test_thread();

    enqueue(core, &spinner);
    dispatch(core, pick_next(core).?, 0);

    _ = on_tick(core, config.level_quanta_ns[0]);

    try testing.expectEqual(@as(u8, 1), spinner.scheduling.level);
    try testing.expectEqual(config.level_quanta_ns[1], spinner.scheduling.quantum_remaining_ns);

}

test "a thread that keeps its quantum keeps the core and the level" {

    init(1);

    const core = current_core();

    var worker = test_thread();

    enqueue(core, &worker);
    dispatch(core, pick_next(core).?, 0);

    const next = on_tick(core, config.level_quanta_ns[0] / 2);

    try testing.expectEqual(&worker, next.?);
    try testing.expectEqual(@as(u8, 0), worker.scheduling.level);

}

test "blocking and waking keeps the level" {

    init(1);

    const core = current_core();

    var sleeper = test_thread();
    sleeper.scheduling.level = 2;

    var placeholder = object.Object{ .kind = .notification };

    enqueue(core, &sleeper);
    dispatch(core, pick_next(core).?, 0);

    sleeper.state = .blocked_notify;
    sleeper.blocked_on = &placeholder;
    defer_dispatch(&sleeper);

    block(core, &sleeper);

    unblock(core, &sleeper);

    try testing.expectEqual(@as(u8, 2), sleeper.scheduling.level);
    try testing.expectEqual(&sleeper, pick_next(core).?);

}

test "sleepers wake onto the run queue only once their deadline passes" {

    init(1);

    const core = current_core();

    var early = test_thread();
    var late = test_thread();

    early.wake_at_ns = 100;
    late.wake_at_ns = 1000;

    // Insert out of deadline order to confirm the list keeps itself sorted.

    core.sleepers = null;
    insert_sleeper(core, &late);
    insert_sleeper(core, &early);

    try testing.expectEqual(&early, core.sleepers.?);

    wake_sleepers(core, 200);

    // `early` is now runnable; `late` stays parked until its own deadline.

    try testing.expectEqual(&early, pick_next(core).?);
    try testing.expectEqual(@as(?*Thread, null), pick_next(core));
    try testing.expectEqual(&late, core.sleepers.?);
    try testing.expectEqual(@as(u64, 1000), earliest_sleeper(core).?);

}

test "the periodic boost returns queued threads to level 0" {

    init(1);

    const core = current_core();

    var starved = test_thread();
    starved.scheduling.level = bottom_level;

    enqueue(core, &starved);

    const next = on_tick(core, config.boost_interval_ns);

    try testing.expectEqual(&starved, next.?);
    try testing.expectEqual(@as(u8, 0), starved.scheduling.level);

}

test "a waiting driver preempts a running normal thread" {

    init(1);

    const core = current_core();

    var worker = test_thread();
    var driver = test_thread();
    driver.scheduling.class = .driver;

    enqueue(core, &worker);
    dispatch(core, pick_next(core).?, 0);

    enqueue(core, &driver);

    const next = on_tick(core, 1);

    try testing.expectEqual(&driver, next.?);
    try testing.expectEqual(ThreadState.ready, worker.state);

}

test "yield hands the core to the next thread at the same level" {

    init(1);

    const core = current_core();

    var first = test_thread();
    var second = test_thread();

    enqueue(core, &first);
    enqueue(core, &second);
    dispatch(core, pick_next(core).?, 0);

    try testing.expectEqual(&first, core.current.?);

    yield();

    try testing.expectEqual(&second, core.current.?);
    try testing.expectEqual(@as(u8, 0), first.scheduling.level);
    try testing.expectEqual(ThreadState.ready, first.state);

}

test "admission round-robins fresh threads across the online cores" {

    init(2);
    register_core(1);

    var first = test_thread();
    var second = test_thread();

    admit(&first);
    admit(&second);

    // One thread per core, whichever the cursor picked first.

    const on_zero = pop_local(&cores[0]);
    const on_one = pop_local(&cores[1]);

    try testing.expect(on_zero != null);
    try testing.expect(on_one != null);
    try testing.expect(on_zero != on_one);

}

test "an idle core steals a queued thread from a loaded peer" {

    init(2);
    register_core(1);

    var backlog = test_thread();

    enqueue(&cores[0], &backlog);

    try testing.expectEqual(&backlog, pick_next(&cores[1]).?);
    try testing.expectEqual(@as(?*Thread, null), pick_next(&cores[1]));

}

test "offline cores are skipped by admission and stealing" {

    init(2);

    var first = test_thread();
    var second = test_thread();

    admit(&first);
    admit(&second);

    try testing.expect(pop_local(&cores[1]) == null);
    try testing.expect(pop_local(&cores[0]) != null);
    try testing.expect(pop_local(&cores[0]) != null);

}

test "donation lends the caller's state and settling accounts it back" {

    init(1);

    var caller = test_thread();
    var server = test_thread();

    caller.scheduling.level = 0;
    caller.scheduling.quantum_remaining_ns = config.level_quanta_ns[0];

    server.scheduling.level = bottom_level;

    donate(&caller, &server);

    // The server now serves at the caller's level: no priority inversion through a low-priority server.

    try testing.expectEqual(@as(u8, 0), server.scheduling.level);
    try testing.expectEqual(@as(u8, bottom_level), server.donated_scheduling.?.level);

    // The request burned some of the donated quantum before the reply.

    server.scheduling.quantum_remaining_ns = config.level_quanta_ns[0] / 2;

    settle_donation(&server, &caller);

    try testing.expectEqual(config.level_quanta_ns[0] / 2, caller.scheduling.quantum_remaining_ns);
    try testing.expectEqual(@as(u8, bottom_level), server.scheduling.level);
    try testing.expectEqual(@as(?SchedulingState, null), server.donated_scheduling);

}

test "a second donation does not clobber the server's own saved state" {

    init(1);

    var caller = test_thread();
    var other = test_thread();
    var server = test_thread();

    server.scheduling.level = 3;
    other.scheduling.level = 2;

    donate(&caller, &server);
    donate(&other, &server);

    try testing.expectEqual(@as(u8, 3), server.donated_scheduling.?.level);

}

test "a normal caller never demotes a driver-class server" {

    init(1);

    var caller = test_thread();
    var driver = test_thread();

    driver.scheduling.class = .driver;

    donate(&caller, &driver);

    try testing.expectEqual(Class.driver, driver.scheduling.class);
    try testing.expectEqual(@as(?SchedulingState, null), driver.donated_scheduling);

    // Settling with nothing donated is a no-op for both sides.

    settle_donation(&driver, &caller);

    try testing.expectEqual(@as(u8, 0), caller.scheduling.level);

}

const ThreadState = thread_module.ThreadState;
