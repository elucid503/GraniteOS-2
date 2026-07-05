// Flint: the startup program. Parses the boot bundle, starts user-space services, and supervises them.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const sys = lib.sys;

const Handle = cap.Handle;

const page_size = 4096;
const child_budget = 4 * 1024 * 1024;
const files_budget = 8 * 1024 * 1024;
const marble_budget = 16 * 1024 * 1024;

var bundle: lib.bundle.Bundle = undefined;
var bundle_length: usize = 0;
var bundle_offset: usize = 0;

var console_endpoint: Handle = 0;
var naming_endpoint: Handle = 0;
var supervisor_endpoint: Handle = 0;
var block_endpoint: Handle = 0;
var files_endpoint: Handle = 0;

var console_uart: lib.dtb.Uart = undefined;
var block_device: ?lib.dtb.Device = null;

const naming_id: u64 = 1;
const console_id: u64 = 2;
const marble_id: u64 = 3;
const block_id: u64 = 4;
const files_id: u64 = 5;

// The filesystem attaches its block session under this badge; badge 0 stays the shared console/logging session.

const files_block_badge: u64 = 1;

pub export fn _start() linksection(".text.start") callconv(.naked) noreturn {

    asm volatile (
        \\ mov x29, xzr
        \\ mov x30, xzr
        \\ b   flint_enter
    );

}

export fn flint_enter(arg: u64) callconv(.c) noreturn {

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

    const dtb_base = try sys.map(cap.self_space, cap.flint.dtb, 0, sys.read);
    const dtb = dtb_base + dtb_offset;

    console_uart = lib.dtb.find_uart(dtb) orelse return error.NotFound;
    block_device = find_block_device(dtb);

    const bundle_base = try sys.map(cap.self_space, cap.flint.module, 0, sys.read);
    bundle = try lib.bundle.Bundle.open(bundle_base + bundle_offset, bundle_length);

    naming_endpoint = try sys.create(.endpoint, 0, 0);
    console_endpoint = try sys.create(.endpoint, 0, 0);
    supervisor_endpoint = try sys.create(.endpoint, 0, 0);
    block_endpoint = try sys.create(.endpoint, 0, 0);
    files_endpoint = try sys.create(.endpoint, 0, 0);

    try spawn_naming();
    try spawn_console();
    try lib.stream.register_with(naming_endpoint, "console", console_endpoint);
    try lib.stream.register_with(naming_endpoint, "naming", naming_endpoint);

    if (block_device != null) {

        try spawn_block();
        try lib.stream.register_with(naming_endpoint, "filesystem", files_endpoint);

    }

    // The filesystem server is spawned either way: without a disk it reports unavailable and exits cleanly
    // (07-userspace-ddd.md Section 7.2), and the shell still comes up.

    try spawn_files();

    try spawn_marble();

}

// Probe each virtio-mmio transport from the DTB for a block device (device id 2). The transports are 0x200-byte
// windows sharing pages, so probing maps the containing page and reads at the in-page offset.

const virtio_magic: u32 = 0x7472_6976;
const device_id_block: u32 = 2;
const max_transports = 64;

fn find_block_device(dtb: usize) ?lib.dtb.Device {

    var nodes: [max_transports]lib.dtb.Device = undefined;
    const count = lib.dtb.find_compatible(dtb, "virtio,mmio", &nodes);

    for (nodes[0..count]) |node| {

        if (probe_block(node)) return node;

    }

    return null;

}

fn probe_block(node: lib.dtb.Device) bool {

    const page = node.base & ~@as(usize, page_size - 1);
    const window = sys.create_device_region(page, page_size, cap.flint.devices) catch return false;

    const mapped = sys.map(cap.self_space, window, 0, sys.read | sys.write) catch {

        sys.close(window) catch {};

        return false;

    };

    const regs = mapped + (node.base - page);

    const magic: *volatile u32 = @ptrFromInt(regs + 0x00);
    const version: *volatile u32 = @ptrFromInt(regs + 0x04);
    const device_id: *volatile u32 = @ptrFromInt(regs + 0x08);

    const found = magic.* == virtio_magic and (version.* == 1 or version.* == 2) and device_id.* == device_id_block;

    sys.unmap(cap.self_space, mapped) catch {};
    sys.close(window) catch {};

    return found;

}

fn spawn_naming() !void {

    const image = bundle.find("naming") orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, child_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, naming_id);

    const grants = [_]Handle{

        naming_endpoint,
        naming_endpoint,
        naming_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
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
    const window = try sys.create_device_region(console_uart.base, page_size, cap.flint.devices);
    const interrupt = try sys.create(.interrupt, console_uart.interrupt_line, cap.flint.interrupts);
    const memory = try sys.create(.memory_authority, child_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, console_id);

    const grants = [_]Handle{

        console_endpoint,
        console_endpoint,
        console_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
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

fn spawn_block() !void {

    const device = block_device orelse return error.NotFound;

    const image = bundle.find("block") orelse return error.NotFound;
    const page = device.base & ~@as(usize, page_size - 1);
    const window = try sys.create_device_region(page, page_size, cap.flint.devices);
    const interrupt = try sys.create(.interrupt, device.interrupt_line, cap.flint.interrupts);
    const memory = try sys.create(.memory_authority, child_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, block_id);

    const grants = [_]Handle{

        block_endpoint,
        block_endpoint,
        block_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        window,
        interrupt,
        cap.flint.dma,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"block"},
        .grants = &grants,
        .data3 = device.base - page,

    });

}

fn spawn_files() !void {

    const image = bundle.find("filesystem") orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, files_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, files_id);
    const block = try sys.copy(block_endpoint, files_block_badge);

    const grants = [_]Handle{

        files_endpoint,
        files_endpoint,
        files_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        block,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"filesystem"},
        .grants = &grants,
        .data3 = if (block_device != null) 1 else 0,

    });

}

fn spawn_marble() !void {

    const image = bundle.find("marble") orelse return error.NotFound;
    const badged_console = try sys.copy(console_endpoint, 1);
    const memory = try sys.create(.memory_authority, marble_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, marble_id);

    const grants = [_]Handle{

        badged_console,
        badged_console,
        badged_console,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        badged_console,
        badged_console,
        cap.flint.module,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"marble"},
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

            if (block_device != null) {

                try lib.stream.register_with(naming_endpoint, "filesystem", files_endpoint);

            }

        },

        console_id => {

            try spawn_console();
            try lib.stream.register_with(naming_endpoint, "console", console_endpoint);

        },

        marble_id => try spawn_marble(),

        block_id => {

            if (block_device != null) try spawn_block();

        },

        // Without a disk the filesystem's exit is its clean "unavailable" report, not a crash to heal.

        files_id => {

            if (block_device != null) try spawn_files();

        },

        else => {},

    }

}
