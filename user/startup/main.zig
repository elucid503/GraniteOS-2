// The Startup Binary (07-userspace-ddd.md Section 4; 04-boot-and-bootstrap.md): the root of the user-space tree and the only fully-authorized process. It parses the DTB, carves hardware and memory out of its bootstrap bundle, and spawns the console driver and the shell as least-privilege processes. Supervision (restart on death) arrives with M5; ELF loading and the module bundle with M6.

const lib = @import("lib");
const console = @import("console");
const shell = @import("shell");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;

comptime {

    _ = lib.start; // pull in `_start`, the raw-mapped image's entry

}

// The link-time image extent (user/linker/user.ld); children run the same static image at the same base.

extern const __image_start: u8;
extern const __image_end: u8;

const page_size = 4096;
const stack_pages = 16;

// Each child's memory-authority slice (hierarchical-lite, 06-kernel-ddd.md Section 11).

const child_budget = 4 * 1024 * 1024;

// The pristine boot module, mapped read-only once and copied per child.

var module_base: usize = 0;

// The supervision state: the console's request endpoint and hardware, plus the endpoint children report their exit to.
// Held so a death message can respawn exactly the child that died (07-userspace-ddd.md Section 4).

var console_endpoint: Handle = 0;
var supervisor_endpoint: Handle = 0;
var console_uart: lib.dtb.Uart = undefined;

// Badges identifying each supervised child on the supervisor endpoint (07-userspace-ddd.md Section 10.4).

const console_id: u64 = 1;
const shell_id: u64 = 2;

pub fn main(dtb_offset: u64) noreturn {

    // A failure before the console driver is up parks silently; once children are running we become their supervisor.

    run(dtb_offset) catch {};

    supervise();

}

fn run(dtb_offset: u64) !void {

    // Hardware discovery lives up here now: the kernel handed over the DTB, not device addresses.

    const dtb_base = try sys.map(cap.self_space, cap.startup.dtb, 0, sys.read);
    console_uart = lib.dtb.find_uart(dtb_base + dtb_offset) orelse return error.NotFound;

    module_base = try sys.map(cap.self_space, cap.startup.module, 0, sys.read);

    console_endpoint = try sys.create(.endpoint, 0, 0);
    supervisor_endpoint = try sys.create(.endpoint, 0, 0);

    try spawn_console();
    try spawn_shell();

}

// The console driver gets exactly its hardware: the UART window, the UART line, its request endpoint, a memory slice,
// and a badged supervisor endpoint to report exit on (grant order = cap.driver).

fn spawn_console() !void {

    const window = try sys.create_device_region(console_uart.base, page_size, cap.startup.devices);
    const interrupt = try sys.create(.interrupt, console_uart.interrupt_line, cap.startup.interrupts);
    const memory = try sys.create(.memory_authority, child_budget, cap.startup.memory);
    const report = try sys.copy(supervisor_endpoint, console_id);

    const space = try sys.create(.address_space, 0, 0);
    const stack_top = try build_child(space);

    _ = try sys.spawn(space, entry_of(&console.main), stack_top, &.{ console_endpoint, window, interrupt, memory, report });

}

// The shell gets a badged copy of the console endpoint (so the driver can tell it apart), a memory slice, and a badged
// supervisor endpoint to report exit on (grant order = cap.shell).

fn spawn_shell() !void {

    const badged = try sys.copy(console_endpoint, 1);
    const memory = try sys.create(.memory_authority, child_budget, cap.startup.memory);
    const report = try sys.copy(supervisor_endpoint, shell_id);

    const space = try sys.create(.address_space, 0, 0);
    const stack_top = try build_child(space);

    _ = try sys.spawn(space, entry_of(&shell.main), stack_top, &.{ badged, memory, report });

}

// Give `space` a private copy of the image at the fixed link base (fresh data/BSS from the pristine module) and a
// stack; returns the initial stack pointer. The image and stack Regions stay held here - the Startup Binary owns its
// children's memory until supervision (M5) reaps them.

fn build_child(space: Handle) !usize {

    const image_base = @intFromPtr(&__image_start);
    const length = @intFromPtr(&__image_end) - image_base;

    const image = try sys.create(.region, length, cap.startup.memory);

    const staging = try sys.map(cap.self_space, image, 0, sys.read | sys.write);
    const source: [*]const u8 = @ptrFromInt(module_base);
    const destination: [*]u8 = @ptrFromInt(staging);

    @memcpy(destination[0..length], source[0..length]);

    try sys.unmap(cap.self_space, staging);

    // The first kernel-chosen mapping in a fresh space lands at the user window base - the link base.

    const mapped = try sys.map(space, image, 0, sys.read | sys.write | sys.execute);

    if (mapped != image_base) return error.Invalid;

    const stack = try sys.create(.region, stack_pages * page_size, cap.startup.memory);
    const stack_base = try sys.map(space, stack, 0, sys.read | sys.write);

    return stack_base + stack_pages * page_size;

}

// Children enter their program's `main` directly; identical link addresses make our pointer their entry.

fn entry_of(function: *const fn (u64) callconv(.c) noreturn) usize {

    return @intFromPtr(function);

}

// The top-level supervisor (07-userspace-ddd.md Section 4): block on the supervisor endpoint for children's one-way
// death messages; the sender's badge names the child, and we respawn it. A crashed server's blocked clients wake with
// `Gone` (06-kernel-ddd.md Section 9) and retry against the restarted endpoint.

fn supervise() noreturn {

    var message = ipc.Message.zeroed;

    while (true) {

        const who = sys.receive(supervisor_endpoint, &message) catch continue;

        restart(who) catch {};

    }

}

fn restart(who: u64) !void {

    switch (who) {

        shell_id => try spawn_shell(),

        // A driver holds a hardware line until its old process is fully reaped; the respawn is best-effort until then
        // (resource reclamation is a tracked M5 follow-up), so a failure here is caught by the supervisor loop.

        console_id => try spawn_console(),

        else => {},

    }

}
