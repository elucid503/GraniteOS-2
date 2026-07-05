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

// The compositor allocates the back buffer and every window surface, so its budget scales with the display.
const compositor_budget = 64 * 1024 * 1024;

var bundle: lib.bundle.Bundle = undefined;
var bundle_length: usize = 0;
var bundle_offset: usize = 0;
var machine_core_count: u64 = 1;

var console_endpoint: Handle = 0;
var naming_endpoint: Handle = 0;
var supervisor_endpoint: Handle = 0;
var block_endpoint: Handle = 0;
var files_endpoint: Handle = 0;
var display_endpoint: Handle = 0;
var input_endpoint: Handle = 0;
var window_endpoint: Handle = 0;

var console_uart: lib.dtb.Uart = undefined;
var block_device: ?lib.dtb.Device = null;

// The graphical stack is optional by hardware presence (08-roadmap.md M9): it spawns only when the DTB
// probe finds a virtio-gpu transport, exactly as the filesystem hinges on a block device.

const max_input_devices = 4;

var gpu_device: ?lib.dtb.Device = null;
var input_devices: [max_input_devices]lib.dtb.Device = undefined;
var input_count: usize = 0;

const naming_id: u64 = 1;
const console_id: u64 = 2;
const marble_id: u64 = 3;
const block_id: u64 = 4;
const files_id: u64 = 5;
const display_id: u64 = 6;
const input_id: u64 = 7;
const compositor_id: u64 = 8;
const welcome_id: u64 = 9;
const demo_id: u64 = 10;

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
    find_virtio_devices(dtb);
    machine_core_count = @max(1, lib.dtb.core_count(dtb));

    const bundle_base = try sys.map(cap.self_space, cap.flint.module, 0, sys.read);
    bundle = try lib.bundle.Bundle.open(bundle_base + bundle_offset, bundle_length);

    naming_endpoint = try sys.create(.endpoint, 0, 0);
    console_endpoint = try sys.create(.endpoint, 0, 0);
    supervisor_endpoint = try sys.create(.endpoint, 0, 0);
    block_endpoint = try sys.create(.endpoint, 0, 0);
    files_endpoint = try sys.create(.endpoint, 0, 0);
    display_endpoint = try sys.create(.endpoint, 0, 0);
    input_endpoint = try sys.create(.endpoint, 0, 0);
    window_endpoint = try sys.create(.endpoint, 0, 0);

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

    if (gpu_device != null) {

        try spawn_display();
        try lib.stream.register_with(naming_endpoint, "display", display_endpoint);

        if (input_count > 0) {

            try spawn_input();
            try lib.stream.register_with(naming_endpoint, "input", input_endpoint);

        }

        // Flint owns the window endpoint, so it registers the name up front: clients resolve "window"
        // immediately and their calls simply block until the compositor starts receiving.

        try spawn_compositor();
        try lib.stream.register_with(naming_endpoint, "window", window_endpoint);
        try spawn_welcome();

    }

}

// Probe each virtio-mmio transport from the DTB and sort them by device id: block (2), gpu (16), input (18).
// The transports are 0x200-byte windows sharing pages, so probing maps the containing page and reads at the
// in-page offset.

const virtio_magic: u32 = 0x7472_6976;
const device_id_block: u32 = 2;
const device_id_gpu: u32 = 16;
const device_id_input: u32 = 18;
const max_transports = 64;

fn find_virtio_devices(dtb: usize) void {

    var nodes: [max_transports]lib.dtb.Device = undefined;
    const count = lib.dtb.find_compatible(dtb, "virtio,mmio", &nodes);

    for (nodes[0..count]) |node| {

        switch (probe_virtio(node)) {

            device_id_block => {

                if (block_device == null) block_device = node;

            },

            device_id_gpu => {

                if (gpu_device == null) gpu_device = node;

            },

            device_id_input => {

                if (input_count < max_input_devices) {

                    input_devices[input_count] = node;
                    input_count += 1;

                }

            },

            else => {},

        }

    }

}

fn probe_virtio(node: lib.dtb.Device) u32 {

    const page = node.base & ~@as(usize, page_size - 1);
    const window = sys.create_device_region(page, page_size, cap.flint.devices) catch return 0;

    const mapped = sys.map(cap.self_space, window, 0, sys.read | sys.write) catch {

        sys.close(window) catch {};

        return 0;

    };

    const regs = mapped + (node.base - page);

    const magic: *volatile u32 = @ptrFromInt(regs + 0x00);
    const version: *volatile u32 = @ptrFromInt(regs + 0x04);
    const device_id: *volatile u32 = @ptrFromInt(regs + 0x08);

    const found: u32 = if (magic.* == virtio_magic and (version.* == 1 or version.* == 2)) device_id.* else 0;

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
        .data5 = machine_core_count,

    });

}

fn spawn_display() !void {

    const device = gpu_device orelse return error.NotFound;

    const image = bundle.find("display") orelse return error.NotFound;
    const page = device.base & ~@as(usize, page_size - 1);
    const window = try sys.create_device_region(page, page_size, cap.flint.devices);
    const interrupt = try sys.create(.interrupt, device.interrupt_line, cap.flint.interrupts);
    const memory = try sys.create(.memory_authority, child_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, display_id);

    const grants = [_]Handle{

        display_endpoint,
        display_endpoint,
        display_endpoint,
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
        .args = &.{"display"},
        .grants = &grants,
        .data3 = device.base - page,

    });

}

fn spawn_input() !void {

    const image = bundle.find("input") orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, child_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, input_id);

    // Standard grants, then the per-device windows and interrupts, then the DMA sub-grant (cap.input).

    var grants: [cap.reserved_grants + 2 * max_input_devices + 1]Handle = undefined;
    var offsets: u64 = 0;

    grants[0] = input_endpoint;
    grants[1] = input_endpoint;
    grants[2] = input_endpoint;
    grants[3] = naming_endpoint;
    grants[4] = memory;
    grants[5] = init_endpoint;
    grants[6] = report;

    for (input_devices[0..input_count], 0..) |device, index| {

        const page = device.base & ~@as(usize, page_size - 1);

        grants[cap.input.devices + index] = try sys.create_device_region(page, page_size, cap.flint.devices);
        grants[cap.input.devices + input_count + index] = try sys.create(.interrupt, device.interrupt_line, cap.flint.interrupts);

        offsets |= @as(u64, device.base - page) << @intCast(16 * index);

    }

    grants[cap.input.dma(input_count)] = cap.flint.dma;

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"input"},
        .grants = grants[0 .. cap.input.dma(input_count) + 1],
        .data3 = input_count,
        .data4 = offsets,

    });

}

fn spawn_compositor() !void {

    const image = bundle.find("compositor") orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, compositor_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, compositor_id);
    const display = try sys.copy(display_endpoint, 1);
    const input = try sys.copy(input_endpoint, 1);

    const grants = [_]Handle{

        window_endpoint,
        window_endpoint,
        window_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        display,
        input,
        cap.flint.module,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{"compositor"},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,

    });

}

fn spawn_gui_program(name: []const u8, id: u64) !void {

    const image = bundle.find(name) orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, child_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, id);

    const grants = [_]Handle{

        console_endpoint,
        console_endpoint,
        console_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        cap.flint.module,

    };

    _ = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = &.{name},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,

    });

}

fn spawn_welcome() !void {

    try spawn_gui_program("welcome", welcome_id);

}

fn spawn_demo() !void {

    try spawn_gui_program("demo", demo_id);

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

        display_id => {

            if (gpu_device != null) {

                try spawn_display();
                try lib.stream.register_with(naming_endpoint, "display", display_endpoint);

            }

        },

        input_id => {

            if (gpu_device != null and input_count > 0) try spawn_input();

        },

        compositor_id => {

            if (gpu_device != null) {

                try spawn_compositor();
                try lib.stream.register_with(naming_endpoint, "window", window_endpoint);

            }

        },

        // The GUI hand-off cycle: the welcome screen's exit is the click-through to the demo, and closing
        // the demo returns to the welcome screen (08-roadmap.md M9).

        welcome_id => {

            if (gpu_device != null) try spawn_demo();

        },

        demo_id => {

            if (gpu_device != null) try spawn_welcome();

        },

        else => {},

    }

}
