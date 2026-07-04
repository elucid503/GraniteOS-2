// MLFQ scheduler core (06-kernel-ddd.md Section 10): per-core queues, the fixed driver band, quantum accounting, demotion, and the periodic boost. Single-core for M2 - work-stealing, IPIs, and scheduling donation arrive with M8; the policy is separated from the switch so it host-tests.

const builtin = @import("builtin");

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const object = @import("../object/object.zig");
const runqueue = @import("runqueue.zig");

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

};

const bottom_level = config.scheduling_levels - 1;

// While idle, tick at the shortest quantum so the boost still fires and admissions are picked up.

const idle_heartbeat_ns = config.level_quanta_ns[0];

var cores: [config.max_cores]Core = undefined;

pub fn init() void {

    cores[0] = .{

        .id = 0,
        .current = null,

        .driver_queue = .{},
        .levels = [_]RunQueue{.{}} ** config.scheduling_levels,

        .idle_context = undefined,
        .last_boost_ns = arch.now_ns(),

        .space_root = 0,
        .zombie = null,

    };

}

/// Secondary cores join here (M8).
pub fn register_core(core_id: u32) void {

    _ = core_id;

}

pub fn current_core() *Core {

    return &cores[arch.core_id()];

}

/// Admit a fresh thread; round-robin across cores once there is more than one (M8).
pub fn admit(thread: *Thread) void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    enqueue(current_core(), thread);

}

/// Timer tick: charge elapsed time, demote on quantum exhaustion, periodic global boost,
/// then return the thread that should run next (or null for idle). Pure policy - no switch.
pub fn on_tick(core: *Core, now_ns: u64) ?*Thread {

    boost(core, now_ns);

    if (core.current) |current| {

        const elapsed = now_ns - current.scheduling.last_started_ns;

        if (elapsed >= current.scheduling.quantum_remaining_ns) {

            demote(current);
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

            enqueue(core, current);
            core.current = null;

        }

    }

    if (core.current) |current| return current;

    return pick_next(core);

}

pub fn pick_next(core: *Core) ?*Thread {

    if (core.driver_queue.pop()) |thread| return thread;

    for (&core.levels) |*level| {

        if (level.pop()) |thread| return thread;

    }

    return steal_from_peers(core);

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

    enqueue(core, current);
    core.current = null;

    reschedule(core, current, pick_next(core), now, .pending);

}

/// Park the current thread on `on`; the caller set the blocked state and holds interrupts off.
/// Blocking before the quantum runs out keeps the level (I/O-bound threads stay responsive).
pub fn block(core: *Core, thread: *Thread, on: *object.Object) void {

    thread.blocked_on = on;

    if (core.current != thread) return;

    core.current = null;

    reschedule(core, thread, pick_next(core), arch.now_ns(), .pending);

}

/// Wake `thread` on the waker's core - it is cache-warm there (06-kernel-ddd.md Section 10 wakeup locality).
pub fn unblock(waker: *Core, thread: *Thread) void {

    thread.blocked_on = null;

    enqueue(waker, thread);

}

/// The IPC direct hand-off (06-kernel-ddd.md Section 9): switch straight from `from` to a already-waiting `to` on
/// this core, no run-queue trip. `from` is blocking (the caller set its state); the caller already removed `to` from
/// the endpoint's receiver queue. Priority/quantum donation is integrated in M8; for now `to` runs on its own state.
pub fn hand_off(from: *Thread, to: *Thread) void {

    const core = current_core();

    to.blocked_on = null;
    core.current = null;

    reschedule(core, from, to, arch.now_ns(), .pending);

}

/// Retire the running thread. Its alive reference is dropped here; if that was the last one, the object is reaped by
/// the next thread once we are off this thread's stack (freeing a running stack in place is not safe).
pub fn exit_current() noreturn {

    _ = arch.disable_interrupts();

    const core = current_core();
    const current = core.current.?;

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

// The trampoline in `asm/switch.S` calls this the instant a freshly-scheduled thread lands, so a thread that exited
// to make room for it is reaped even when its successor is starting for the first time.

export fn kernel_after_switch() callconv(.c) void {

    reap(current_core());

}

// The trampoline in `asm/switch.S` lands here when a kernel thread's entry function returns.

export fn kernel_thread_return() callconv(.c) noreturn {

    exit_current();

}

/// The primary core's hand-off into scheduling: from here on it is the idle path.
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
// context (or the idle context). Runs with interrupts off; a preempted thread resumes here.

fn reschedule(core: *Core, previous: ?*Thread, next: ?*Thread, now_ns: u64, deadline: Deadline) void {

    if (next) |thread| {

        dispatch(core, thread, now_ns);

        if (thread != previous or deadline == .consumed) {

            arch.arm_deadline(thread.scheduling.quantum_remaining_ns);

        }

        if (thread != previous) {

            activate_space(core, thread);

            const save_into = if (previous) |p| &p.context else &core.idle_context;

            arch.switch_context(save_into, &thread.context);
            reap(core);

        }

    } else {

        arch.arm_deadline(idle_heartbeat_ns);

        if (previous) |p| {

            arch.switch_context(&p.context, &core.idle_context);
            reap(core);

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

// Anti-starvation aging: every boost interval, all normal threads return to level 0.

fn boost(core: *Core, now_ns: u64) void {

    if (now_ns - core.last_boost_ns < config.boost_interval_ns) return;

    core.last_boost_ns = now_ns;

    for (core.levels[1..]) |*level| {

        while (level.pop()) |thread| {

            thread.scheduling.level = 0;
            thread.scheduling.quantum_remaining_ns = config.level_quanta_ns[0];
            core.levels[0].push(thread);

        }

    }

    if (core.current) |current| {

        if (current.scheduling.class == .normal) current.scheduling.level = 0;

    }

}

fn quantum_of(thread: *const Thread) u64 {

    if (thread.scheduling.class == .driver) return config.level_quanta_ns[0];

    return config.level_quanta_ns[thread.scheduling.level];

}

fn steal_from_peers(core: *Core) ?*Thread {

    _ = core;

    // Work-stealing arrives with M8; one core never has peers to rob.

    return null;

}

const testing = @import("std").testing;

fn test_thread() Thread {

    var thread: Thread = undefined;

    thread.state = .ready;
    thread.scheduling = .{};
    thread.queue_link = .{};
    thread.blocked_on = null;

    return thread;

}

test "a spinning thread demotes one level per exhausted quantum" {

    init();

    const core = current_core();

    var spinner = test_thread();

    enqueue(core, &spinner);
    dispatch(core, pick_next(core).?, 0);

    _ = on_tick(core, config.level_quanta_ns[0]);

    try testing.expectEqual(@as(u8, 1), spinner.scheduling.level);
    try testing.expectEqual(config.level_quanta_ns[1], spinner.scheduling.quantum_remaining_ns);

}

test "a thread that keeps its quantum keeps the core and the level" {

    init();

    const core = current_core();

    var worker = test_thread();

    enqueue(core, &worker);
    dispatch(core, pick_next(core).?, 0);

    const next = on_tick(core, config.level_quanta_ns[0] / 2);

    try testing.expectEqual(&worker, next.?);
    try testing.expectEqual(@as(u8, 0), worker.scheduling.level);

}

test "blocking and waking keeps the level" {

    init();

    const core = current_core();

    var sleeper = test_thread();
    sleeper.scheduling.level = 2;

    var placeholder = object.Object{ .kind = .notification };

    enqueue(core, &sleeper);
    dispatch(core, pick_next(core).?, 0);

    sleeper.state = .blocked_notify;
    block(core, &sleeper, &placeholder);

    unblock(core, &sleeper);

    try testing.expectEqual(@as(u8, 2), sleeper.scheduling.level);
    try testing.expectEqual(&sleeper, pick_next(core).?);

}

test "the periodic boost returns queued threads to level 0" {

    init();

    const core = current_core();

    var starved = test_thread();
    starved.scheduling.level = bottom_level;

    enqueue(core, &starved);

    const next = on_tick(core, config.boost_interval_ns);

    try testing.expectEqual(&starved, next.?);
    try testing.expectEqual(@as(u8, 0), starved.scheduling.level);

}

test "a waiting driver preempts a running normal thread" {

    init();

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

    init();

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

const ThreadState = thread_module.ThreadState;
