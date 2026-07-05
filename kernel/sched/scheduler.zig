// MLFQ scheduler core (06-kernel-ddd.md Section 10): per-core queues, the fixed driver band, quantum accounting,
// demotion, and the periodic boost. SMP since M8: cores join at the discovered count, fresh threads round-robin,
// idle cores steal, and IPC hand-offs donate the caller's scheduling state until the reply. Per-core queues are
// guarded by their own spinlock (stealers reach in); everything else per-core is touched only by its core.

const builtin = @import("builtin");
const std = @import("std");

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const object = @import("../object/object.zig");
const runqueue = @import("runqueue.zig");
const spinlock = @import("../sync/spinlock.zig");
const ipc_sync = @import("../sync/ipc.zig");

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

    // The address-space root currently loaded in TTBR0, so a switch within one process skips the TLB flush.
    space_root: PhysAddr,

    // A thread that exited on this core; freed by the next thread once it is off the dead thread's stack.
    zombie: ?*Thread,

    // Guards the two queue sets above; taken by this core and by peers stealing from it.
    lock: spinlock.SpinLock,

    // The thread being switched away from; whoever runs next on this core publishes its saved context.
    outgoing: ?*Thread,

    online: bool,

};

const bottom_level = config.scheduling_levels - 1;

// While idle, tick at the shortest quantum so the boost still fires and admissions are picked up.

const idle_heartbeat_ns = config.level_quanta_ns[0];

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

            .idle_context = undefined,
            .last_boost_ns = arch.now_ns(),

            .space_root = 0,
            .zombie = null,

            .lock = .{},
            .outgoing = null,

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

/// Timer tick: charge elapsed time, demote on quantum exhaustion, periodic global boost,
/// then return the thread that should run next (or null for idle). Pure policy - no switch.
pub fn on_tick(core: *Core, now_ns: u64) ?*Thread {

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

// Work-stealing: an idle core robs the MLFQ of the next online peer that has anything queued.
// Only one runqueue lock is ever held at a time, so stealing cannot deadlock against a stealing peer.

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

/// Park the current thread; the caller set its blocked state, queued it, and called `defer_dispatch`,
/// all under the IPC lock (released again before coming here). Blocking before the quantum runs out
/// keeps the level (I/O-bound threads stay responsive).
pub fn block(core: *Core, thread: *Thread) void {

    if (core.current != thread) return;

    core.current = null;

    reschedule(core, thread, pick_next(core), arch.now_ns(), .pending);

}

/// Wake `thread` on the waker's core - it is cache-warm there (06-kernel-ddd.md Section 10 wakeup locality).
/// Callers hold the IPC lock, which is what serializes competing wakers.
pub fn unblock(waker: *Core, thread: *Thread) void {

    thread.blocked_on = null;

    enqueue(waker, thread);

}

/// Wake a thread blocked in send/call because its peer died (06-kernel-ddd.md Section 9): its syscall unwinds as `Gone`.
pub fn abort_ipc(thread: *Thread) void {

    thread.ipc_aborted = true;
    thread.awaiting_reply = false;

    unblock(current_core(), thread);

}

/// The IPC direct hand-off (06-kernel-ddd.md Section 9): switch straight from `from` to an already-waiting `to` on
/// this core, no run-queue trip. The caller parked `from`, cleared `to`'s wait state, and donated `from`'s
/// scheduling under the IPC lock.
pub fn hand_off(from: *Thread, to: *Thread) void {

    const core = current_core();

    core.current = null;

    reschedule(core, from, to, arch.now_ns(), .pending);

}

/// The reply-time switch straight back to the caller (06-kernel-ddd.md Section 9): the server goes ready
/// on this core's queue and the caller resumes immediately on its donated-back state.
pub fn hand_back(server: *Thread, caller: *Thread) void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = current_core();

    defer_dispatch(server);
    enqueue(core, server);
    core.current = null;

    reschedule(core, server, caller, arch.now_ns(), .pending);

}

/// Lend the caller's scheduling state to the server until the matching reply (06-kernel-ddd.md Section 10 donation):
/// the server serves at the caller's priority and its time is accounted to the caller. Held under the IPC lock.
/// Donation cures priority inversion, so it only ever raises the server - a driver-class server keeps its band
/// when a normal client calls it.
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

/// Undo a donation at reply: the caller takes back the (depleted) state its request ran on, the server
/// returns to its own.
pub fn settle_donation(server: *Thread, caller: *Thread) void {

    const own = server.donated_scheduling orelse return;

    caller.scheduling = server.scheduling;
    server.scheduling = own;
    server.donated_scheduling = null;

}

/// Mark a running thread's saved context as stale before it becomes poppable by another core; the switch
/// path republishes it once the register frame is really parked (the wake-before-save handshake).
pub fn defer_dispatch(thread: *Thread) void {

    @atomicStore(bool, &thread.context_saved, false, .monotonic);

}

fn wait_context_saved(thread: *Thread) void {

    while (!@atomicLoad(bool, &thread.context_saved, .acquire)) {

        std.atomic.spinLoopHint();

    }

}

/// Retire the running thread. Its alive reference is dropped here; if that was the last one, the object is reaped by
/// the next thread once we are off this thread's stack (freeing a running stack in place is not safe).
pub fn exit_current() noreturn {

    _ = arch.disable_interrupts();

    const core = current_core();
    const current = core.current.?;

    // Fault-aware teardown (06-kernel-ddd.md Section 9): wake anyone this thread owed a reply or blocked toward.

    ipc_sync.lock.lock();
    current.release_ipc();
    ipc_sync.lock.unlock();

    current.state = .dead;
    core.current = null;

    if (current.header.release()) core.zombie = current;

    reschedule(core, current, pick_next(core), arch.now_ns(), .pending);

    unreachable;

}

// Free a thread that exited on this core. Safe only once we have switched onto another stack, so it runs from the
// point a thread resumes a switch (or first reaches a trampoline), never on the exiting thread itself.

fn reap(core: *Core) void {

    if (core.zombie) |zombie| {

        core.zombie = null;
        object.destroy(&zombie.header);

    }

}

// Runs the moment anything lands on this core after a switch: publish the outgoing thread's saved context
// (peers spinning in `wait_context_saved` may now dispatch it) and reap any exited predecessor.

fn after_switch(core: *Core) void {

    if (core.outgoing) |previous| {

        core.outgoing = null;

        @atomicStore(bool, &previous.context_saved, true, .release);

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

/// A core's hand-off into scheduling (the primary after boot, secondaries after registering): the idle path.
pub fn idle() noreturn {

    arch.arm_deadline(idle_heartbeat_ns);
    arch.enable_interrupts();

    while (true) {

        arch.wait_for_event();

    }

}

// Whether the armed timer deadline is still pending. A voluntary reschedule that keeps the
// same thread must leave it alone - re-arming on every yield would postpone the tick (and
// the boost) forever under a tight yield loop.

const Deadline = enum {

    consumed,
    pending,

};

// Re-arm the deadline as needed and switch to the chosen thread, saving into `previous`'s
// context (or the idle context). Runs with interrupts off; a preempted thread resumes here
// (possibly on a different core, so the post-switch bookkeeping re-reads the current core).

fn reschedule(core: *Core, previous: ?*Thread, next: ?*Thread, now_ns: u64, deadline: Deadline) void {

    if (next) |thread| {

        if (thread == previous) {

            // Re-picked without leaving the core: its live context was never stale.

            @atomicStore(bool, &thread.context_saved, true, .release);

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

        arch.arm_deadline(idle_heartbeat_ns);

        if (previous) |p| {

            core.outgoing = p;
            arch.switch_context(&p.context, &core.idle_context);
            after_switch(current_core());

        }

    }

}

// Load the incoming thread's page-table root into TTBR0 when it differs from what is live. Every process root shares
// the kernel's top-level entry, so kernel code keeps running after the switch (config.user_space_base). Host test
// builds have no MMU and construct threads without a real process, so the activation is compiled out there.

fn activate_space(core: *Core, thread: *Thread) void {

    if (builtin.is_test) return;

    const root = thread.process.address_space.root;

    if (root == core.space_root) return;

    core.space_root = root;
    arch.activate_space(root);

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
