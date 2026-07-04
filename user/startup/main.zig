// The Startup Binary: parses the boot bundle, starts user-space services, and supervises them.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const sys = lib.sys;

const Handle = cap.Handle;

const page_size = 4096;
const child_budget = 4 * 1024 * 1024;
const shell_budget = 16 * 1024 * 1024;

var bundle: lib.bundle.Bundle = undefined;
var bundle_length: usize = 0;
var bundle_offset: usize = 0;

var console_endpoint: Handle = 0;
var naming_endpoint: Handle = 0;
var supervisor_endpoint: Handle = 0;
var console_uart: lib.dtb.Uart = undefined;

const naming_id: u64 = 1;
const console_id: u64 = 2;
const shell_id: u64 = 3;

pub export fn _start() linksection(".text.start") callconv(.naked) noreturn {

    asm volatile (
        \\ mov x29, xzr
        \\ mov x30, xzr
        \\ b   startup_enter
    );

}

export fn startup_enter(arg: u64) callconv(.c) noreturn {

    main(arg);

}

fn main(arg: u64) noreturn {

    run(arg) catch {};

    supervise();

}

fn run(arg: u64) !void {

    const dtb_offset: usize = @intCast(arg & 0xffff);
    bundle_offset = @intCast((arg >> 16) & 0xffff);
    bundle_length = @intCast(arg >> 32);

    const dtb_base = try sys.map(cap.self_space, cap.startup.dtb, 0, sys.read);
    console_uart = lib.dtb.find_uart(dtb_base + dtb_offset) orelse return error.NotFound;

    const bundle_base = try sys.map(cap.self_space, cap.startup.module, 0, sys.read);
    bundle = try lib.bundle.Bundle.open(bundle_base + bundle_offset, bundle_length);

    naming_endpoint = try sys.create(.endpoint, 0, 0);
    console_endpoint = try sys.create(.endpoint, 0, 0);
    supervisor_endpoint = try sys.create(.endpoint, 0, 0);

    try spawn_naming();
    try spawn_console();
    try lib.stream.register_with(naming_endpoint, "console", console_endpoint);
    try lib.stream.register_with(naming_endpoint, "naming", naming_endpoint);
    try spawn_shell();

}

fn spawn_naming() !void {

    const image = bundle.find("naming") orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, child_budget, cap.startup.memory);
    const startup = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, naming_id);

    const grants = [_]Handle{

        naming_endpoint,
        naming_endpoint,
        naming_endpoint,
        naming_endpoint,
        memory,
        startup,
        report,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"naming"},
        .grants = &grants,

    });

}

fn spawn_console() !void {

    const image = bundle.find("console") orelse return error.NotFound;
    const window = try sys.create_device_region(console_uart.base, page_size, cap.startup.devices);
    const interrupt = try sys.create(.interrupt, console_uart.interrupt_line, cap.startup.interrupts);
    const memory = try sys.create(.memory_authority, child_budget, cap.startup.memory);
    const startup = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, console_id);

    const grants = [_]Handle{

        console_endpoint,
        console_endpoint,
        console_endpoint,
        naming_endpoint,
        memory,
        startup,
        report,
        window,
        interrupt,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"console"},
        .grants = &grants,

    });

}

fn spawn_shell() !void {

    const image = bundle.find("shell") orelse return error.NotFound;
    const badged_console = try sys.copy(console_endpoint, 1);
    const memory = try sys.create(.memory_authority, shell_budget, cap.startup.memory);
    const startup = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, shell_id);

    const grants = [_]Handle{

        badged_console,
        badged_console,
        badged_console,
        naming_endpoint,
        memory,
        startup,
        report,
        badged_console,
        badged_console,
        cap.startup.module,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"shell"},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,

    });

}

fn supervise() noreturn {

    var message = ipc.Message.zeroed;

    while (true) {

        const who = sys.receive(supervisor_endpoint, &message) catch continue;

        restart(who) catch {};

    }

}

fn restart(who: u64) !void {

    switch (who) {

        naming_id => {

            try spawn_naming();
            try lib.stream.register_with(naming_endpoint, "console", console_endpoint);
            try lib.stream.register_with(naming_endpoint, "naming", naming_endpoint);

        },

        console_id => {

            try spawn_console();
            try lib.stream.register_with(naming_endpoint, "console", console_endpoint);

        },

        shell_id => try spawn_shell(),

        else => {},

    }

}
