// Flint: the startup program. Parses the boot bundle, starts user-space services, and supervises them.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const sys = lib.sys;

const Handle = cap.Handle;

const page_size = 4096;
const child_budget = 4 * 1024 * 1024;
// Virtio-sound pulls a larger image/BSS than the other MMIO drivers; keep headroom for DMA + console log session.
const audio_budget = 8 * 1024 * 1024;
const files_budget = 8 * 1024 * 1024;
const marble_budget = 16 * 1024 * 1024;

// Desktop wallpaper decode needs a multi-megabyte pixel buffer (1920x1080 XRGB plus inflate scratch).
const context_budget = 32 * 1024 * 1024;

// The compositor allocates the back buffer and every window surface, so its budget scales with the display.
const compositor_budget = 64 * 1024 * 1024;

// The launcher holds one shared pool for all GUI children (see lib.budget); keep it small enough that welcome still
// spawns on the default 256 MiB QEMU machine.
const launcher_budget = lib.budget.launcher_pool;

var bundle: lib.bundle.Bundle = undefined;
var bundle_length: usize = 0;
var bundle_offset: usize = 0;
var machine_core_count: u64 = 1;

var console_endpoint: Handle = 0;
var naming_endpoint: Handle = 0;
var supervisor_endpoint: Handle = 0;
var block_endpoint: Handle = 0;
var audio_endpoint: Handle = 0;
var files_endpoint: Handle = 0;
var display_endpoint: Handle = 0;
var input_endpoint: Handle = 0;
var window_endpoint: Handle = 0;
var launcher_endpoint: Handle = 0;

var console_uart: lib.dtb.Uart = undefined;
var block_device: ?lib.dtb.Device = null;
var audio_device: ?lib.dtb.Device = null;

// The graphical stack is optional by hardware presence (08-roadmap.md M9): it spawns only when fw_cfg
// exposes `etc/ramfb` (QEMU `-device ramfb`) together with virtio input.

const max_input_devices = 4;

var fw_cfg_device: ?lib.dtb.Device = null;
var ramfb_present = false;
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
const launcher_id: u64 = 11;
const taskbar_id: u64 = 12;
const context_id: u64 = 13;
const audio_id: u64 = 14;

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
    audio_endpoint = try sys.create(.endpoint, 0, 0);
    files_endpoint = try sys.create(.endpoint, 0, 0);
    display_endpoint = try sys.create(.endpoint, 0, 0);
    input_endpoint = try sys.create(.endpoint, 0, 0);
    window_endpoint = try sys.create(.endpoint, 0, 0);
    launcher_endpoint = try sys.create(.endpoint, 0, 0);

    try spawn_naming();
    try spawn_console();
    try lib.stream.register_with(naming_endpoint, "console", console_endpoint);
    try lib.stream.register_with(naming_endpoint, "naming", naming_endpoint);

    // Probe ramfb after the console is up so failures are visible on serial.
    find_ramfb(dtb);

    if (block_device != null) {

        try spawn_block();
        try lib.stream.register_with(naming_endpoint, "filesystem", files_endpoint);

    }

    // The filesystem server is spawned either way: without a disk it reports unavailable and exits cleanly
    // (07-userspace-ddd.md Section 7.2), and the shell still comes up.

    try spawn_files();

    if (audio_device != null) {

        // The driver registers "audio" itself after a successful bind so a failed init never leaves a dead name that hangs clients forever on attach.
        try spawn_audio();

    }

    try spawn_marble();

    start_gui() catch {};

}

fn start_gui() !void {

    if (ramfb_present) {

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

        // The launcher server backs the taskbar's app menu; register it up front too so the menu resolves it
        // immediately. The welcome screen is the splash - clicking it hands off to the persistent taskbar desktop.

        try spawn_launcher();
        try lib.stream.register_with(naming_endpoint, "launch", launcher_endpoint);

        // The desktop wallpaper layer sits beneath the welcome splash so the handoff never shows bare compositor fill.
        // Taskbar starts only after welcome exits (panels would otherwise cover the splash).
        try spawn_context();
        try spawn_welcome();

    }

}

// Probe each virtio-mmio transport from the DTB and sort them by device id: block (2), input (18), sound (25).
// Display no longer uses virtio-gpu; ramfb is discovered through fw_cfg (`etc/ramfb`).
// The transports are 0x200-byte windows sharing pages, so probing maps the containing page and reads at the
// in-page offset.

const virtio_magic: u32 = 0x7472_6976;
const device_id_block: u32 = 2;
const device_id_input: u32 = 18;
const device_id_sound: u32 = 25;
const max_transports = 64;

fn find_virtio_devices(dtb: usize) void {

    var nodes: [max_transports]lib.dtb.Device = undefined;
    const count = lib.dtb.find_compatible(dtb, "virtio,mmio", &nodes);

    for (nodes[0..count]) |node| {

        switch (probe_virtio(node)) {

            device_id_block => {

                if (block_device == null) block_device = node;

            },

            device_id_input => {

                if (input_count < max_input_devices) {

                    input_devices[input_count] = node;
                    input_count += 1;

                }

            },

            device_id_sound => {

                if (audio_device == null) audio_device = node;

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

// QEMU virt fw_cfg is at 0x09020000; prefer the DTB node when present (no interrupt required).
const fw_cfg_fallback_base: usize = 0x0902_0000;

fn find_ramfb(dtb: usize) void {

    var nodes: [1]lib.dtb.Device = undefined;

    fw_cfg_device = if (lib.dtb.find_compatible(dtb, "qemu,fw-cfg-mmio", &nodes) > 0)
        nodes[0]
    else
        .{ .base = fw_cfg_fallback_base, .interrupt_line = 0 };

    ramfb_present = probe_ramfb(fw_cfg_device.?);

}

fn probe_ramfb(device: lib.dtb.Device) bool {

    const page = device.base & ~@as(usize, page_size - 1);
    const window = sys.create_device_region(page, page_size, cap.flint.devices) catch return false;

    const mapped = sys.map(cap.self_space, window, 0, sys.read | sys.write) catch {

        sys.close(window) catch {};

        return false;

    };

    const scratch = sys.create_dma(page_size, cap.flint.dma) catch {

        sys.unmap(cap.self_space, mapped) catch {};
        sys.close(window) catch {};

        return false;

    };

    const scratch_va = sys.map(cap.self_space, scratch.region, 0, sys.read | sys.write) catch {

        sys.close(scratch.region) catch {};
        sys.unmap(cap.self_space, mapped) catch {};
        sys.close(window) catch {};

        return false;

    };

    @memset(@as([*]u8, @ptrFromInt(scratch_va))[0..page_size], 0);

    const regs = mapped + (device.base - page);
    const fw = lib.fw_cfg.FwCfg.init(regs, scratch_va, scratch.physical_base);
    const found = fw.present() and fw.find(lib.fw_cfg.ramfb_name) != null;

    sys.unmap(cap.self_space, scratch_va) catch {};
    sys.close(scratch.region) catch {};
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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"naming"},
        .grants = &grants,

    }, &.{ memory, init_endpoint, report });

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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"console"},
        .grants = &grants,

    }, &.{ window, interrupt, memory, init_endpoint, report });

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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"block"},
        .grants = &grants,
        .data3 = device.base - page,

    }, &.{ window, interrupt, memory, init_endpoint, report });

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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"filesystem"},
        .grants = &grants,
        .data3 = if (block_device != null) 1 else 0,

    }, &.{ memory, init_endpoint, report, block });

}

fn spawn_audio() !void {

    const device = audio_device orelse return error.NotFound;
    const image = bundle.find("audio") orelse return error.NotFound;
    const page = device.base & ~@as(usize, page_size - 1);
    const window = try sys.create_device_region(page, page_size, cap.flint.devices);
    const interrupt = try sys.create(.interrupt, device.interrupt_line, cap.flint.interrupts);
    const memory = try sys.create(.memory_authority, audio_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, audio_id);

    const grants = [_]Handle{

        audio_endpoint,
        audio_endpoint,
        audio_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        window,
        interrupt,
        cap.flint.dma,

    };

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"audio"},
        .grants = &grants,
        .data3 = device.base - page,

    }, &.{ window, interrupt, memory, init_endpoint, report });

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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"marble"},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,
        .data5 = machine_core_count,

    }, &.{ badged_console, memory, init_endpoint, report });

}

fn spawn_display() !void {

    const device = fw_cfg_device orelse return error.NotFound;

    const image = bundle.find("display") orelse return error.NotFound;
    const page = device.base & ~@as(usize, page_size - 1);
    const window = try sys.create_device_region(page, page_size, cap.flint.devices);
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
        cap.flint.dma,

    };

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"display"},
        .grants = &grants,
        .data3 = device.base - page,

    }, &.{ window, memory, init_endpoint, report });

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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"input"},
        .grants = grants[0 .. cap.input.dma(input_count) + 1],
        .data3 = input_count,
        .data4 = offsets,

    }, grants[cap.memory .. cap.input.dma(input_count)]);

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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"compositor"},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,

    }, &.{ memory, init_endpoint, report, display, input });

}

fn spawn_launcher() !void {

    const image = bundle.find("launcher") orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, launcher_budget, cap.flint.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor_endpoint, launcher_id);

    // Layout per cap.launcher: the request endpoint in the stdio slots, then naming, its budget, startup, report, a
    // console endpoint to pass on to GUI children, and the module bundle to load their images from.

    const grants = [_]Handle{

        launcher_endpoint,
        launcher_endpoint,
        launcher_endpoint,
        naming_endpoint,
        memory,
        init_endpoint,
        report,
        console_endpoint,
        cap.flint.module,

    };

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{"launcher"},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,
        .data5 = machine_core_count,

    }, &.{ memory, init_endpoint, report });

}

fn spawn_gui_program(name: []const u8, id: u64) !void {

    try spawn_gui_program_budget(name, id, child_budget);

}

fn spawn_gui_program_budget(name: []const u8, id: u64, budget: u64) !void {

    const image = bundle.find(name) orelse return error.NotFound;
    const memory = try sys.create(.memory_authority, budget, cap.flint.memory);
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

    try spawn_detached(.{

        .image = image,
        .authority = memory,
        .args = &.{name},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,

    }, &.{ memory, init_endpoint, report });

}

fn spawn_detached(args: lib.elf.SpawnArgs, owned: []const Handle) !void {

    errdefer close_handles(owned);

    const child = try lib.elf.spawn_program(args);

    sys.close(child) catch {};
    close_handles(owned);

}

fn close_handles(handles: []const Handle) void {

    for (handles) |handle| {

        sys.close(handle) catch {};

    }

}

fn spawn_welcome() !void {

    try spawn_gui_program("welcome", welcome_id);

}

fn spawn_taskbar() !void {

    try spawn_gui_program("taskbar", taskbar_id);

}

fn spawn_context() !void {

    try spawn_gui_program_budget("context", context_id, context_budget);

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

        audio_id => {

            if (audio_device != null) try spawn_audio();

        },

        // Without a disk the filesystem's exit is its clean "unavailable" report, not a crash to heal.

        files_id => {

            if (block_device != null) try spawn_files();

        },

        display_id => {

            if (ramfb_present) {

                try spawn_display();
                try lib.stream.register_with(naming_endpoint, "display", display_endpoint);

            }

        },

        input_id => {

            if (ramfb_present and input_count > 0) try spawn_input();

        },

        compositor_id => {

            if (ramfb_present) {

                try spawn_compositor();
                try lib.stream.register_with(naming_endpoint, "window", window_endpoint);

            }

        },

        launcher_id => {

            if (ramfb_present) {

                try spawn_launcher();
                try lib.stream.register_with(naming_endpoint, "launch", launcher_endpoint);

            }

        },

        // The welcome splash hands off to the taskbar on exit; the taskbar is the persistent desktop, so it is
        // relaunched if it ever dies. The rest of the apps are user-launched through the launcher.

        welcome_id => {

            if (ramfb_present) try spawn_taskbar();

        },

        taskbar_id => {

            if (ramfb_present) try spawn_taskbar();

        },

        context_id => {

            if (ramfb_present) try spawn_context();

        },

        else => {},

    }

}
