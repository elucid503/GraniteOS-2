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
var console_base: usize = 0;
var console_endpoint: Handle = 0;

pub fn main(dtb_offset: u64) noreturn {

    // Failures before the console driver is up still park silently; after that, `report` writes over the Stream.

    run(dtb_offset) catch {};

    park();

}

fn run(dtb_offset: u64) !void {

    // Hardware discovery lives up here now: the kernel handed over the DTB, not device addresses.

    const dtb_base = try sys.map(cap.self_space, cap.startup.dtb, 0, sys.read);
    const uart = lib.dtb.find_uart(dtb_base + dtb_offset) orelse return error.NotFound;

    module_base = try sys.map(cap.self_space, cap.startup.module, 0, sys.read);

    const endpoint = try sys.create(.endpoint, 0, 0);

    try spawn_console(endpoint, uart);
    open_console(endpoint) catch {};
    put_console("startup: console session up\n") catch {};

    spawn_shell(endpoint) catch |e| {

        report("startup: shell spawn failed: ", e);
        return e;

    };

}

// The console driver gets exactly its hardware: the UART window, the UART line, its endpoint, and a memory slice
// (grant order = cap.driver).

fn spawn_console(endpoint: Handle, uart: lib.dtb.Uart) !void {

    const window = try sys.create_device_region(uart.base, page_size, cap.startup.devices);
    const interrupt = try sys.create(.interrupt, uart.interrupt_line, cap.startup.interrupts);
    const memory = try sys.create(.memory_authority, child_budget, cap.startup.memory);

    const space = try sys.create(.address_space, 0, 0);
    const stack_top = try build_child(space);

    _ = try sys.spawn(space, entry_of(&console.main), stack_top, &.{ endpoint, window, interrupt, memory });

}

// The shell gets a badged copy of the console endpoint (so the driver can tell it apart) and a memory slice
// (grant order = cap.shell).

fn spawn_shell(endpoint: Handle) !void {

    const badged = try sys.copy(endpoint, 1);
    const memory = try sys.create(.memory_authority, child_budget, cap.startup.memory);

    const space = try sys.create(.address_space, 0, 0);
    const stack_top = try build_child(space);

    _ = try sys.spawn(space, entry_of(&shell.main), stack_top, &.{ badged, memory });

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

fn open_console(endpoint: Handle) !void {

    console_endpoint = endpoint;

    const buffer = try sys.create(.region, page_size, cap.startup.memory);
    console_base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);

    _ = try ipc.request(endpoint, proto.stream.attach, &.{page_size}, &.{

        .{ .handle = buffer, .move = false },

    });

}

fn put_console(text: []const u8) !void {

    if (console_base == 0) return error.Invalid;

    const buffer: [*]u8 = @ptrFromInt(console_base);
    @memcpy(buffer[0..text.len], text);

    _ = try ipc.request(console_endpoint, proto.stream.write, &.{ 0, text.len }, &.{});

}

fn report(prefix: []const u8, failure: anyerror) void {

    put_console(prefix) catch {};
    put_console(@errorName(failure)) catch {};
    put_console("\n") catch {};

}

// Children enter their program's `main` directly; identical link addresses make our pointer their entry.

fn entry_of(function: *const fn (u64) callconv(.c) noreturn) usize {

    return @intFromPtr(function);

}

// Nothing to supervise yet (M5): block forever on a notification nobody signals.

fn park() noreturn {

    const idle = sys.create(.notification, 0, 0) catch lib.start.exit();

    while (true) {

        _ = sys.wait(idle) catch {};

    }

}
