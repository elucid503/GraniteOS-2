// Build the aarch64 freestanding kernel, M7 user module bundle, the persistent disk image, and QEMU `virt` run steps.

const std = @import("std");
const builtin = @import("builtin");

const discover = @import("build/discover.zig");

const bytes_per_mib = 1024 * 1024;
const default_disk_mib = 64;

pub fn build(b: *std.Build) void {

    const release = b.option(bool, "release", "Build optimized guest binaries") orelse true;
    const optimize: std.builtin.OptimizeMode = if (release) .ReleaseFast else .Debug;
    const test_build = b.option(bool, "test", "Exit QEMU via semihosting on halt/panic") orelse false;
    const smp = b.option(u64, "smp", "Core count for the QEMU run steps") orelse 4;
    const memory = b.option(u64, "memory", "RAM in MiB for the QEMU run steps") orelse 512;
    const disk = b.option(u64, "disk", "Disk size in MiB for the persistent QEMU disk") orelse default_disk_mib;
    const debug_syscall_trace = b.option(bool, "debug-syscall-trace", "Record the last syscall verb/args in globals for panic diagnosis") orelse false;
    const net = b.option(bool, "net", "Attach virtio-net (QEMU user-mode networking, host reachable at 10.0.2.2) to the QEMU run steps") orelse true;

    if (disk == 0) @panic("-Ddisk must be at least 1 MiB");
    if (disk > std.math.maxInt(u64) / bytes_per_mib) @panic("-Ddisk is too large");

    const disk_bytes = disk * bytes_per_mib;

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 },

    });

    // The kernel is FP/SIMD-free: it context-switches user FP state lazily and must never itself clobber a user
    // thread's live vector registers during a syscall or IRQ (Stage 1.1). Dropping fp_armv8/neon from its target
    // guarantees the compiler emits no NEON in kernel code; user modules keep FP for the NEON userspace paths.

    const kernel_target = b.resolveTargetQuery(.{

        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 },
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon }),

    });

    const options = b.addOptions();
    options.addOption(bool, "test", test_build);
    options.addOption(bool, "debug_syscall_trace", debug_syscall_trace);

    // No RTC and no NTP-capable datagram sockets exist yet, so the taskbar clock seeds its wall-clock
    // offset from the build machine's real time (see user/lib/localtime.zig) - accurate as long as the
    // gap between building and booting stays small, which it does for a normal build-then-run loop.
    options.addOption(i64, "build_epoch_s", std.time.timestamp());

    // The kernel is SMP since M8: single_threaded would let the compiler lower its atomics away.

    const kernel_module = b.createModule(.{

        .root_source_file = b.path("kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .single_threaded = false,
        .pic = false,

    });

    kernel_module.addImport("build_options", options.createModule());
    kernel_module.addAssemblyFile(b.path("kernel/arch/aarch64/asm/start.S"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/aarch64/asm/vectors.S"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/aarch64/asm/switch.S"));

    const kernel = b.addExecutable(.{

        .name = "granite-kernel.elf",
        .root_module = kernel_module,

    });

    kernel.setLinkerScript(b.path("kernel/arch/aarch64/asm/linker.ld"));
    kernel.entry = .{ .symbol_name = "_start" };

    // User modules are multithreaded since M7: pooled servers run worker threads (07-userspace-ddd.md Section 7.2).

    const user_lib = b.createModule(.{

        .root_source_file = b.path("user/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
        .pic = false,

    });

    user_lib.addImport("build_options", options.createModule());

    var module_arena = std.heap.ArenaAllocator.init(b.allocator);
    defer module_arena.deinit();

    const modules = discover.scan(module_arena.allocator()) catch @panic("user module discovery failed");

    var artifacts = std.StringArrayHashMap(*std.Build.Step.Compile).init(b.allocator);
    defer artifacts.deinit();

    for (modules) |module| {

        if (module.kind == .asset) continue;

        const exe = user_program(b, target, optimize, user_lib, module.elf_name, module.source);

        artifacts.put(module.bundle_name, exe) catch @panic("duplicate bundle module name");

    }

    const catalog_bytes = discover.generate_catalog_bytes(module_arena.allocator(), modules) catch @panic("catalog generation failed");
    const catalog_step = b.addWriteFiles();
    const catalog_file = catalog_step.add("app-catalog.bin", catalog_bytes);

    const flatten = host_tool(b, "flatten", "tools/flatten.zig");
    const bundle_tool = host_tool(b, "bundle", "tools/bundle.zig");
    const seedisk = host_seedisk(b);
    const qemu_runner = host_tool(b, "qemu-run", "tools/qemu-run.zig");

    const kernel_image = flatten_image(b, flatten, kernel, "granite-kernel.bin");
    const flint = artifacts.get("flint") orelse @panic("missing flint module");
    const flint_image = flatten_image(b, flatten, flint, "flint.bin");

    const bundle_run = b.addRunArtifact(bundle_tool);
    const bundle_image = bundle_run.addOutputFileArg("bundle.img");

    add_module(bundle_run, "flint", flint_image);

    for (modules) |module| {

        if (module.kind == .asset) continue;

        const exe = artifacts.get(module.bundle_name) orelse @panic("missing bundle artifact");

        if (std.mem.eql(u8, module.bundle_name, "flint")) continue;

        add_artifact_module(bundle_run, module.bundle_name, exe);

    }

    bundle_run.step.dependOn(&catalog_step.step);
    add_module(bundle_run, "app-catalog", catalog_file);

    // GUI assets ride in the bundle as plain modules.

    add_module(bundle_run, "font-ttf", b.path("user/fonts/InterVariable.ttf"));
    add_module(bundle_run, "font-mono", b.path("user/fonts/JetBrainsMono-Regular.ttf"));

    // Theme wallpapers (user/images/wallpaper/default); one PNG per color theme.
    add_module(bundle_run, "wp-monochrome", b.path("user/images/wallpaper/default/monochrome.png"));
    add_module(bundle_run, "wp-ocean", b.path("user/images/wallpaper/default/ocean.png"));
    add_module(bundle_run, "wp-forest", b.path("user/images/wallpaper/default/forest.png"));
    add_module(bundle_run, "wp-sunset", b.path("user/images/wallpaper/default/sunset.png"));
    add_module(bundle_run, "wp-grape", b.path("user/images/wallpaper/default/grape.png"));

    b.installArtifact(kernel);
    b.getInstallStep().dependOn(&b.addInstallBinFile(kernel_image, "granite-kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(flint_image, "flint.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(bundle_image, "bundle.img").step);

    // The persistent virtio disk: created once, then reused across runs so the filesystem survives reboots.

    const disk_path = b.pathFromRoot(if (disk == default_disk_mib) "disk.img" else b.fmt("disk-{d}M.img", .{disk}));
    const seedisk_run = b.addRunArtifact(seedisk);

    seedisk_run.addArg(disk_path);
    seedisk_run.addArg(b.fmt("{d}", .{disk_bytes}));

    for (modules) |module| {

        if (module.kind != .program) continue;

        const exe = artifacts.get(module.bundle_name) orelse @panic("missing seedisk artifact");

        add_seed_program(seedisk_run, module.bundle_name, exe);

    }

    seedisk_run.addArg("/root/user/demos/demo.wav");
    seedisk_run.addFileArg(b.path("user/audio/demo.wav"));

    seedisk_run.has_side_effects = true;

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu",
        .description = "Boot the full M7 system under QEMU `virt` with the persistent disk",
        .debug = false,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = seedisk_run },
        .smp = smp,
        .memory = memory,
        .net = net,

    }, null);

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-debug",
        .description = "Boot the full M7 system under QEMU `virt`, halted, with a gdb stub on :1234",
        .debug = true,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = seedisk_run },
        .smp = smp,
        .memory = memory,
        .net = net,

    }, null);

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-gui",
        .description = "Boot the full system with the virtio-gpu display and virtio-input devices (M9)",
        .debug = false,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = seedisk_run },
        .smp = smp,
        .memory = memory,
        .gui = true,
        .net = net,

    }, qemu_runner);

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-nodisk",
        .description = "Boot the full system without a disk (the filesystem reports unavailable)",
        .debug = false,
        .test_build = test_build,
        .disk = null,
        .smp = smp,
        .memory = memory,
        .net = net,

    }, null);

    add_qemu_step(b, kernel_image, null, .{

        .name = "qemu-bare",
        .description = "Boot the kernel without an initrd (halts after initialization)",
        .debug = false,
        .test_build = test_build,
        .disk = null,
        .smp = smp,
        .memory = memory,

    }, null);

    const kernel_tests = b.addTest(.{

        .root_module = b.createModule(.{

            .root_source_file = b.path("kernel/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,

        }),

    });

    const host_user_lib = b.createModule(.{

        .root_source_file = b.path("user/lib/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,

    });

    host_user_lib.addImport("build_options", options.createModule());

    const user_tests_module = b.createModule(.{

        .root_source_file = b.path("user/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,

    });

    user_tests_module.addImport("lib", host_user_lib);

    const user_tests = b.addTest(.{

        .root_module = user_tests_module,

    });

    const test_step = b.step("test", "Run the host unit tests for the kernel core and the user runtime");

    test_step.dependOn(&b.addRunArtifact(kernel_tests).step);
    test_step.dependOn(&b.addRunArtifact(user_tests).step);

}

fn user_program(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, user_lib: *std.Build.Module, name: []const u8, root: []const u8) *std.Build.Step.Compile {

    const module = b.createModule(.{

        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .single_threaded = false,
        .pic = false,

        // Programs are loaded from the module bundle and installed to disk; strip debug info so the images stay small.
        .strip = true,

    });

    module.addImport("lib", user_lib);

    const executable = b.addExecutable(.{

        .name = name,
        .root_module = module,

    });

    executable.setLinkerScript(b.path("user/linker/user.ld"));
    executable.entry = .{ .symbol_name = "_start" };

    return executable;

}

fn host_tool(b: *std.Build, name: []const u8, root: []const u8) *std.Build.Step.Compile {

    return b.addExecutable(.{

        .name = name,
        .root_module = b.createModule(.{

            .root_source_file = b.path(root),
            .target = b.graph.host,
            .optimize = .Debug,

        }),

    });

}

fn host_seedisk(b: *std.Build) *std.Build.Step.Compile {

    const format_module = b.createModule(.{

        .root_source_file = b.path("user/servers/filesystem/format.zig"),
        .target = b.graph.host,
        .optimize = .Debug,

    });

    const root_module = b.createModule(.{

        .root_source_file = b.path("tools/seedisk.zig"),
        .target = b.graph.host,
        .optimize = .Debug,

    });

    root_module.addImport("format", format_module);

    return b.addExecutable(.{

        .name = "seedisk",
        .root_module = root_module,

    });

}

fn flatten_image(b: *std.Build, flatten: *std.Build.Step.Compile, image: *std.Build.Step.Compile, name: []const u8) std.Build.LazyPath {

    const run = b.addRunArtifact(flatten);

    run.addArtifactArg(image);

    return run.addOutputFileArg(name);

}

fn add_module(run: *std.Build.Step.Run, name: []const u8, file: std.Build.LazyPath) void {

    run.addArg(name);
    run.addFileArg(file);

}

fn add_artifact_module(run: *std.Build.Step.Run, name: []const u8, artifact: *std.Build.Step.Compile) void {

    run.addArg(name);
    run.addArtifactArg(artifact);

}

fn add_seed_program(run: *std.Build.Step.Run, name: []const u8, artifact: *std.Build.Step.Compile) void {

    add_artifact_module(run, name, artifact);

}

const QemuDisk = struct {

    path: []const u8,
    prepare: *std.Build.Step.Run,

};

const QemuStep = struct {

    name: []const u8,
    description: []const u8,
    debug: bool,
    test_build: bool,
    disk: ?QemuDisk,
    smp: u64,
    memory: u64,
    gui: bool = false,
    net: bool = false,

};

fn add_qemu_step(b: *std.Build, kernel: std.Build.LazyPath, initrd: ?std.Build.LazyPath, step: QemuStep, qemu_runner: ?*std.Build.Step.Compile) void {

    const run = if (step.gui) blk: {

        const gui_run = b.addRunArtifact(qemu_runner.?);

        gui_run.has_side_effects = true;
        gui_run.addArg("qemu-system-aarch64");

        break :blk gui_run;

    } else blk: {

        break :blk b.addSystemCommand(&.{"qemu-system-aarch64"});

    };

    run.addArgs(&.{
        "-machine", "virt,gic-version=3",
        "-cpu",     "cortex-a57",
        "-smp",     b.fmt("{d}", .{step.smp}),
        "-m",       b.fmt("{d}M", .{step.memory}),
    });

    // VirtIO Sound needs a modern MMIO transport (VIRTIO_F_VERSION_1 / config version 2).
    run.addArgs(&.{ "-global", "virtio-mmio.force-legacy=false" });

    // QEMU user-mode networking (SLIRP): guest 10.0.2.15/24, gateway/host-proxy and DNS at 10.0.2.2/.3 (matches
    // servers/netstack/config.zig's hardcoded addressing). hostfwd lets a host client reach a guest TCP listener;
    // the guest reaches the host itself at 10.0.2.2 for outbound tests (e.g. `fetch`).
    if (step.net) {

        run.addArgs(&.{ "-netdev", "user,id=granite-net,hostfwd=tcp::5555-:5555" });
        run.addArgs(&.{ "-device", "virtio-net-device,netdev=granite-net" });

    }

    // GUI boots open a host display window with the serial console on stdio; everything else is headless.

    if (step.gui) {

        run.addArgs(&.{ "-display", "sdl" });
        run.addArgs(&.{ "-device", "virtio-gpu-device" });
        run.addArgs(&.{ "-device", "virtio-keyboard-device" });
        run.addArgs(&.{ "-device", "virtio-tablet-device" });
        const audio_backend = if (builtin.os.tag == .windows) "dsound,id=granite-audio" else "sdl,id=granite-audio";

        run.addArgs(&.{ "-audiodev", audio_backend });
        // streams=1: playback only. No capture stream, yet...
        run.addArgs(&.{ "-device", "virtio-sound-device,audiodev=granite-audio,streams=1" });
        run.addArgs(&.{ "-serial", "mon:stdio" });

    } else {

        run.addArg("-nographic");

    }

    if (step.test_build) {

        run.addArg("-semihosting");

    }

    if (step.debug) {

        run.addArgs(&.{ "-s", "-S" });

    }

    run.addArg("-kernel");
    run.addFileArg(kernel);

    if (initrd) |image| {

        run.addArg("-initrd");
        run.addFileArg(image);

    }

    if (step.disk) |disk| {

        run.addArgs(&.{ "-drive", b.fmt("if=none,format=raw,id=granite-disk,file={s}", .{disk.path}) });
        run.addArgs(&.{ "-device", "virtio-blk-device,drive=granite-disk" });

        run.step.dependOn(&disk.prepare.step);

    }

    b.step(step.name, step.description).dependOn(&run.step);

}
