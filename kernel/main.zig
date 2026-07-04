// Kernel entry (06-kernel-ddd.md Section 3): discover the machine, take ownership of RAM (M1), bring up the interrupt controller, timer, objects, and scheduler (M2), prove the syscall/IPC spine (M3), then hand off to the Startup Binary (M4).

const std = @import("std");

const arch = @import("arch/arch.zig");
const config = @import("config.zig");
const console = @import("debug/console.zig");
const panic_path = @import("debug/panic.zig");

const dtb = @import("boot/dtb.zig");
const handoff = @import("boot/handoff.zig");
const frames = @import("memory/frames.zig");
const region = @import("memory/region.zig");
const address_space = @import("memory/address_space.zig");
const process_module = @import("object/process.zig");
const thread_module = @import("object/thread.zig");
const endpoint_module = @import("object/endpoint.zig");
const notification_module = @import("object/notification.zig");
const interrupt_module = @import("object/interrupt.zig");
const memory_authority = @import("authority/memory_authority.zig");
const interrupt_authority = @import("authority/interrupt_authority.zig");
const device_authority = @import("authority/device_authority.zig");
const scheduler = @import("sched/scheduler.zig");
const transfer = @import("ipc/transfer.zig");
const programs = @import("user/programs.zig");

const message_module = @import("ipc/message.zig");
const Message = message_module.Message;
const notification_wake = message_module.notification_wake;

const Region = region.Region;
const AddressSpace = address_space.AddressSpace;
const Process = process_module.Process;
const Thread = thread_module.Thread;
const Endpoint = endpoint_module.Endpoint;
const Notification = notification_module.Notification;
const Handle = @import("cap/handle.zig").Handle;

// The M3 user-program blob, bounded by the linker (arch/aarch64/asm/linker.ld); copied into each process and mapped  at EL0 (config.user_space_base).

extern const __user_text_start: u8;
extern const __user_text_end: u8;

// Route language-level panics through the kernel panic path.
pub const panic = std.debug.FullPanic(panic_path.at);

const page_size = config.page_size;

// The kernel image extent, reserved from the frame allocator so it never hands out memory we are running from.

extern const __kernel_start: u8;
extern const __kernel_end: u8;

pub fn main(dtb_address: arch.PhysAddr) noreturn {

    console.debug_print("GraniteOS-2 (aarch64 virt)\n");

    var memory_banks: [8]dtb.MemoryRange = undefined;
    const machine = dtb.parse(dtb_address, &memory_banks) catch {

        panic_path.panic("dtb: could not parse the device tree", null);

    };

    report_machine(machine);

    // The M4 hand-off runs from the M3 overseer thread, long after these locals are gone.

    boot_dtb_address = dtb_address;
    boot_initrd = machine.initrd;

    // Make every discovered RAM bank reachable by its physical address, then take ownership of all of it bar what we occupy.

    arch.map_ram(machine.memory);
    frames.init(machine.memory, &reserved(dtb_address, machine.initrd));
    region.init();
    address_space.init();

    report_frames();
    stress();

    console.debug_print("M1: memory foundation up.\n");

    arch.intctrl_init_primary(machine.intctrl);
    arch.timer_init();

    process_module.init();
    thread_module.init();
    endpoint_module.init();
    notification_module.init();
    interrupt_module.init();
    memory_authority.init();
    interrupt_authority.init();
    device_authority.init();
    scheduler.init();

    start_demo_threads();

    console.debug_print("M2: scheduler up; two threads admitted.\n");
    scheduler.idle();

}

// The M2 exit criterion: two kernel-mode threads time-slice under the timer, demote and boost correctly, and yield works.

var demo_counter: u64 = 0;
var stop_spinner: bool = false;
var spinner_done: bool = false;
var demo_checker: *Thread = undefined;

fn start_demo_threads() void {

    const space = AddressSpace.create() catch oom();
    const kernel_process = Process.create(space) catch oom();

    const spinner = Thread.create(kernel_process, @intFromPtr(&spin)) catch oom();
    demo_checker = Thread.create(kernel_process, @intFromPtr(&run_checks)) catch oom();

    spinner.start();
    demo_checker.start();

}

fn spin(_: u64) callconv(.c) void {

    const counter: *volatile u64 = &demo_counter;
    const stop: *volatile bool = &stop_spinner;

    while (!stop.*) {

        counter.* +%= 1;

    }

    // Cooperative exit so the M3 demo runs without a competing spinner; the entry return retires this thread.

    @as(*volatile bool, &spinner_done).* = true;

}

fn run_checks(_: u64) callconv(.c) void {

    const counter: *volatile u64 = &demo_counter;
    const level: *volatile u8 = &demo_checker.scheduling.level;

    // Time-slicing: the spinner never yields, so its progress proves preemption reached us both.

    const preempted = counter.*;

    while (counter.* < preempted + 100_000) {}

    console.debug_print("M2: time-slice OK\n");

    // Yield: hand over the core and confirm the spinner ran while we were off it.

    const before_yield = counter.*;

    while (counter.* == before_yield) {

        scheduler.yield();

    }

    console.debug_print("M2: yield OK\n");

    // Demotion: burning whole quanta must walk us down to the bottom level.

    while (level.* != config.scheduling_levels - 1) {}

    console.debug_print("M2: demote OK\n");

    // Boost: the periodic anti-starvation boost must lift us back to level 0.

    while (level.* != 0) {}

    console.debug_print("M2: boost OK\n");

    console.debug_print("M2: OK objects and scheduler up\n");

    // Retire the spinner, then hand off to the M3 user-mode demo (this thread becomes its overseer).

    stop_spinner = true;

    while (!@as(*volatile bool, &spinner_done).*) {

        scheduler.yield();

    }

    run_m3();

}

// M3: two user-mode processes complete a call/reply round-trip over a badged endpoint, passing a Region handle, and an IPC micro-benchmark records the round-trip cost (08-roadmap.md M3 "Done when").

const user_code_base = config.user_space_base; // 0x80_0000_0000
const user_stack_base = config.user_space_base + 0x1000_0000;
const user_bootinfo = config.user_space_base + 0x2000_0000;
const user_data = config.user_space_base + 0x3000_0000;

const user_stack_pages = 4;

const readable = arch.Permissions{ .read = true, .user = true };
const read_write = arch.Permissions{ .read = true, .write = true, .user = true };
const read_execute = arch.Permissions{ .read = true, .execute = true, .user = true };

fn run_m3() noreturn {

    const endpoint = Endpoint.create() catch oom();
    const done = Notification.create() catch oom();
    const data = Region.create(page_size) catch oom();

    const client_boot = build_client(endpoint, data, done);
    build_server(endpoint);

    console.debug_print("M3: two user processes spawned; running call/reply.\n");

    // Wait for the client to finish its round-trips and signal completion.

    const overseer = scheduler.current_core().current.?;

    if (done.poll_or_block(overseer) == null) {

        scheduler.block(scheduler.current_core(), overseer, &done.header);

    }

    report_m3(client_boot);

    run_m5();

}

// M5: robustness and multi-wait (08-roadmap.md M5 "Done when"). Two in-kernel demos over the same IPC primitives the
// syscall layer uses: one thread serves a request and an async event through a single `receive` (bound notification),
// and a client blocked in `call` wakes with `Gone` when its server dies without replying. Kernel-mode threads (like the
// M2 demo) drive the transfer path directly, so the proof needs no user image and runs under the bare smoke test.

const M5 = struct {

    var request_ep: *Endpoint = undefined;
    var bound: *Notification = undefined;
    var multi_wait_done: *Notification = undefined;

    var gone_ep: *Endpoint = undefined;
    var gone_done: *Notification = undefined;

    var saw_event: bool = false;
    var saw_request: bool = false;
    var multi_wait_ok: bool = false;
    var gone_ok: bool = false;

    const event_bits: u64 = 0b1010;

};

fn run_m5() noreturn {

    const space = AddressSpace.create() catch oom();
    const kproc = Process.create(space) catch oom();

    // Phase 1 - multi-wait: one thread waits on an endpoint and a notification at once.

    M5.request_ep = Endpoint.create() catch oom();
    M5.bound = Notification.create() catch oom();
    M5.multi_wait_done = Notification.create() catch oom();

    const waiter = Thread.create(kproc, @intFromPtr(&m5_waiter)) catch oom();
    waiter.start();

    // The event may arrive before the waiter first blocks; the pending path in `receive` still reports it.

    M5.bound.signal(M5.event_bits);

    const requester = Thread.create(kproc, @intFromPtr(&m5_requester)) catch oom();
    requester.start();

    overseer_wait(M5.multi_wait_done);

    if (!M5.multi_wait_ok) panic_path.panic("M5: multi-wait did not deliver both a request and an event", null);

    console.debug_print("M5: multi-wait OK\n");

    // Phase 2 - Gone: a client blocked in `call` wakes when its server dies without replying.

    M5.gone_ep = Endpoint.create() catch oom();
    M5.gone_done = Notification.create() catch oom();

    const victim = Thread.create(kproc, @intFromPtr(&m5_victim)) catch oom();
    victim.start();

    const client = Thread.create(kproc, @intFromPtr(&m5_client)) catch oom();
    client.start();

    overseer_wait(M5.gone_done);

    if (!M5.gone_ok) panic_path.panic("M5: a dead server did not wake its blocked caller with Gone", null);

    console.debug_print("M5: gone OK\n");
    console.debug_print("M5: OK robustness and multi-wait up\n");

    run_m4();

}

// The waiter serves both worlds through one `receive`: a bound-notification wake counts as an event, any other wake is
// a request it replies to. Seeing one of each proves single-thread multi-wait; it then reports done and retires.

fn m5_waiter(_: u64) callconv(.c) void {

    const self = scheduler.current_core().current.?;

    M5.bound.bound_to = self;
    self.bound_notification = M5.bound;
    M5.bound.header.retain();

    while (!(M5.saw_event and M5.saw_request)) {

        const badge = transfer.receive(self, M5.request_ep) catch break;

        if (badge == notification_wake) {

            if (self.notify_bits == M5.event_bits) M5.saw_event = true;

        } else {

            M5.saw_request = true;

            self.staged = Message.zeroed;

            transfer.reply(self, self.staged.reply) catch {};

        }

    }

    M5.multi_wait_ok = M5.saw_event and M5.saw_request;
    M5.multi_wait_done.signal(1);

}

fn m5_requester(_: u64) callconv(.c) void {

    const self = scheduler.current_core().current.?;

    self.staged = Message.zeroed;

    transfer.call(self, M5.request_ep) catch {};

}

// The victim receives a call, then dies without replying - exercising the reply-cancellation teardown.

fn m5_victim(_: u64) callconv(.c) void {

    const self = scheduler.current_core().current.?;

    _ = transfer.receive(self, M5.gone_ep) catch {};

}

fn m5_client(_: u64) callconv(.c) void {

    const self = scheduler.current_core().current.?;

    self.staged = Message.zeroed;

    if (transfer.call(self, M5.gone_ep)) |_| {} else |failure| {

        if (failure == error.Gone) M5.gone_ok = true;

    }

    M5.gone_done.signal(1);

}

// Park the overseer on `notification` until a demo thread signals completion (the run_m3 done-handshake pattern).

fn overseer_wait(notification: *Notification) void {

    const overseer = scheduler.current_core().current.?;

    if (notification.poll_or_block(overseer) == null) {

        scheduler.block(scheduler.current_core(), overseer, &notification.header);

    }

}

// M4: hand the machine to the Startup Binary (08-roadmap.md M4 "Done when": an interactive prompt over serial,
// echo through the console driver, a builtin running). Without an initrd there is nothing to hand off to, so the
// boot halts exactly where M3 left it - which keeps the M1-M3 smoke tests terminating.

var boot_dtb_address: arch.PhysAddr = 0;
var boot_initrd: ?dtb.MemoryRange = null;

fn run_m4() noreturn {

    const initrd = boot_initrd orelse {

        console.debug_print("M4: no initrd; halting.\n");
        arch.halt();

    };

    handoff.start(initrd, boot_dtb_address) catch {

        panic_path.panic("M4: boot hand-off failed", null);

    };

    console.debug_print("M4: hand-off complete; the startup binary owns user space.\n");

    // The overseer's work is done; from here on the kernel only schedules, faults, and dispatches syscalls.

    scheduler.exit_current();

}

// Build the client process and start it; returns its bootinfo (read back for the results after it finishes).
fn build_client(endpoint: *Endpoint, data: *Region, done: *Notification) *programs.ClientBootinfo {

    const space = AddressSpace.create() catch oom();
    map_user_code(space);
    const stack_top = map_user_stack(space);

    const boot_region = Region.create(page_size) catch oom();
    _ = space.map(boot_region, user_bootinfo, read_write) catch oom();

    const client = Process.create(space) catch oom();

    const endpoint_handle = client.handles.insert_badged(&endpoint.header, programs.client_badge) catch oom();
    const data_handle = client.handles.insert(&data.header) catch oom();
    const done_handle = client.handles.insert(&done.header) catch oom();

    const boot: *programs.ClientBootinfo = @ptrFromInt(boot_region.base);
    boot.* = .{

        .endpoint = handle_word(endpoint_handle),
        .data_region = handle_word(data_handle),
        .done = handle_word(done_handle),
        .map_at = user_data,

        .iterations = programs.iterations,

        .result_status = 0,
        .result_badge = 0,
        .result_magic = 0,
        .result_ns = 0,

    };

    const entry = user_code_base + offset_of(&programs.user_client);
    const thread = Thread.create_user(client, entry, stack_top, user_bootinfo) catch oom();
    thread.start();

    return boot;

}

// Build the server process via the spawn path (the endpoint is its only grant) and start it.
fn build_server(endpoint: *Endpoint) void {

    const space = AddressSpace.create() catch oom();
    map_user_code(space);
    const stack_top = map_user_stack(space);

    const boot_region = Region.create(page_size) catch oom();
    _ = space.map(boot_region, user_bootinfo, read_write) catch oom();

    // The endpoint is granted at spawn, so it lands at handle 0 in the fresh table (the first insert).

    const boot: *programs.ServerBootinfo = @ptrFromInt(boot_region.base);
    boot.* = .{ .endpoint = 0, .map_at = user_data };

    const entry = user_code_base + offset_of(&programs.user_server);

    const server = Process.spawn(space, entry, stack_top, &.{.{ .object = &endpoint.header }}, user_bootinfo) catch oom();
    _ = server.header.release();

}

// Copy the position-independent user blob into a fresh Region and map it read-execute at the user code base.
fn map_user_code(space: *AddressSpace) void {

    const length = @intFromPtr(&__user_text_end) - @intFromPtr(&__user_text_start);
    const code = Region.create(length) catch oom();

    const destination: [*]u8 = @ptrFromInt(code.base);
    const source: [*]const u8 = @ptrFromInt(@intFromPtr(&__user_text_start));
    @memcpy(destination[0..length], source[0..length]);

    arch.sync_instruction_cache();

    _ = space.map(code, user_code_base, read_execute) catch oom();

}

// Map a fresh read-write stack and return the top (where SP_EL0 starts).
fn map_user_stack(space: *AddressSpace) arch.VirtAddr {

    const stack = Region.create(user_stack_pages * page_size) catch oom();
    _ = space.map(stack, user_stack_base, read_write) catch oom();

    return user_stack_base + user_stack_pages * page_size;

}

fn offset_of(function: *const anyopaque) usize {

    return @intFromPtr(function) - @intFromPtr(&__user_text_start);

}

fn handle_word(handle: Handle) u64 {

    return @as(u32, @bitCast(handle));

}

fn report_m3(boot: *programs.ClientBootinfo) void {

    console.debug_print("M3: round-trip ");
    console.debug_print_hex(boot.result_ns / programs.iterations);
    console.debug_print(" ns\n");

    if (boot.result_status != 0) panic_path.panic("M3: server replied a failure status", null);

    console.debug_print("M3: call/reply OK\n");

    if (boot.result_badge != programs.client_badge) panic_path.panic("M3: server saw the wrong badge", null);

    console.debug_print("M3: badge OK\n");

    if (boot.result_magic != programs.magic) panic_path.panic("M3: passed-handle data did not survive", null);

    console.debug_print("M3: handle-passing OK\n");

    console.debug_print("M3: OK syscalls and IPC spine up\n");

}

// The spans the frame allocator must not hand out: the kernel image, the device tree, and the initrd (if any).
fn reserved(dtb_address: arch.PhysAddr, initrd: ?dtb.MemoryRange) [3]frames.MemoryRange {

    const kernel_base = std.mem.alignBackward(usize, @intFromPtr(&__kernel_start), page_size);
    const kernel_top = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), page_size);

    const dtb_base = std.mem.alignBackward(usize, dtb_address, page_size);
    const dtb_top = std.mem.alignForward(usize, dtb_address + dtb.total_size(dtb_address), page_size);

    var spans = [3]frames.MemoryRange{

        .{ .base = kernel_base, .length = kernel_top - kernel_base },
        .{ .base = dtb_base, .length = dtb_top - dtb_base },
        .{ .base = 0, .length = 0 },
    };

    if (initrd) |modules| {

        const modules_base = std.mem.alignBackward(usize, modules.base, page_size);
        const modules_top = std.mem.alignForward(usize, modules.base + modules.length, page_size);

        spans[2] = .{ .base = modules_base, .length = modules_top - modules_base };

    }

    return spans;

}

fn report_machine(machine: dtb.Machine) void {

    console.debug_print("cores ");
    console.debug_print_hex(machine.core_count);

    for (machine.memory) |bank| {

        console.debug_print("\nram ");
        console.debug_print_hex(bank.base);
        console.debug_print(" + ");
        console.debug_print_hex(bank.length);

    }

    console.debug_putchar('\n');

}

fn report_frames() void {

    const counts = frames.stats();
    console.debug_print("frames total ");
    console.debug_print_hex(counts.total);
    console.debug_print(" free ");
    console.debug_print_hex(counts.free);
    console.debug_putchar('\n');

}

// The M1 exit criterion: allocate, map, verify, unmap, and free frames and regions in a loop, and prove nothing leaked.
fn stress() void {

    const writable = arch.Permissions{ .read = true, .write = true, .user = true };
    const baseline = frames.stats().free;
    const iterations = 1000;

    for (0..iterations) |_| {

        const space = AddressSpace.create() catch oom();
        const memory = Region.create(2 * page_size) catch oom();

        const at = space.map(memory, null, writable) catch oom();

        if (arch.translate(space.root, at) != memory.frame(0)) {

            panic_path.panic("stress: mapping did not resolve to the region", null);

        }

        space.unmap(at) catch unreachable;

        if (arch.translate(space.root, at) != null) {

            panic_path.panic("stress: mapping survived unmap", null);

        }

        memory.destroy();
        space.destroy();

    }

    const after = frames.stats().free;

    console.debug_print("M1 stress ");
    console.debug_print_hex(iterations);
    console.debug_print(" rounds, free ");
    console.debug_print_hex(after);
    console.debug_putchar('\n');

    if (after != baseline) {

        panic_path.panic("stress: frames leaked", null);

    }

    console.debug_print("M1: OK no leaks\n");

}

fn oom() noreturn {

    panic_path.panic("out of memory during the M1 stress loop", null);

}
