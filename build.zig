// Build the aarch64 freestanding kernel, M7 user module bundle, the persistent disk image, and QEMU `virt` run steps.

const std = @import("std");

const bytes_per_mib = 1024 * 1024;
const default_disk_mib = 64;

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{});
    const test_build = b.option(bool, "test", "Exit QEMU via semihosting on halt/panic") orelse false;
    const smp = b.option(u64, "smp", "Core count for the QEMU run steps") orelse 4;
    const memory = b.option(u64, "memory", "RAM in MiB for the QEMU run steps") orelse 256;
    const disk = b.option(u64, "disk", "Disk size in MiB for the persistent QEMU disk") orelse default_disk_mib;

    if (disk == 0) @panic("-Ddisk must be at least 1 MiB");
    if (disk > std.math.maxInt(u64) / bytes_per_mib) @panic("-Ddisk is too large");

    const disk_bytes = disk * bytes_per_mib;

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 },

    });

    const options = b.addOptions();
    options.addOption(bool, "test", test_build);

    // The kernel is SMP since M8: single_threaded would let the compiler lower its atomics away.

    const kernel_module = b.createModule(.{

        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
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

    const flint = user_program(b, target, optimize, user_lib, "granite-flint.elf", "user/flint/main.zig");
    const console = user_program(b, target, optimize, user_lib, "granite-console.elf", "user/drivers/console/main.zig");
    const block = user_program(b, target, optimize, user_lib, "granite-block.elf", "user/drivers/block/main.zig");
    const marble = user_program(b, target, optimize, user_lib, "granite-marble.elf", "user/marble/main.zig");
    const naming = user_program(b, target, optimize, user_lib, "granite-naming.elf", "user/servers/naming/main.zig");
    const filesystem = user_program(b, target, optimize, user_lib, "granite-filesystem.elf", "user/servers/filesystem/main.zig");
    const echo = user_program(b, target, optimize, user_lib, "granite-echo.elf", "user/programs/common/echo.zig");
    const cat = user_program(b, target, optimize, user_lib, "granite-cat.elf", "user/programs/common/cat.zig");
    const help = user_program(b, target, optimize, user_lib, "granite-help.elf", "user/programs/common/help.zig");
    const about = user_program(b, target, optimize, user_lib, "granite-about.elf", "user/programs/common/about.zig");
    const hello = user_program(b, target, optimize, user_lib, "granite-hello.elf", "user/programs/common/hello.zig");
    const clear = user_program(b, target, optimize, user_lib, "granite-clear.elf", "user/programs/common/clear.zig");
    const wc = user_program(b, target, optimize, user_lib, "granite-wc.elf", "user/programs/common/wc.zig");
    const status = user_program(b, target, optimize, user_lib, "granite-status.elf", "user/programs/common/status.zig");
    const location = user_program(b, target, optimize, user_lib, "granite-location.elf", "user/programs/location/location.zig");
    const ls = user_program(b, target, optimize, user_lib, "granite-ls.elf", "user/programs/fs/ls.zig");
    const view = user_program(b, target, optimize, user_lib, "granite-view.elf", "user/programs/fs/view.zig");
    const write = user_program(b, target, optimize, user_lib, "granite-write.elf", "user/programs/fs/write.zig");
    const create = user_program(b, target, optimize, user_lib, "granite-create.elf", "user/programs/fs/create.zig");
    const mkdir = user_program(b, target, optimize, user_lib, "granite-mkdir.elf", "user/programs/fs/mkdir.zig");
    const delete = user_program(b, target, optimize, user_lib, "granite-delete.elf", "user/programs/fs/delete.zig");
    const rename = user_program(b, target, optimize, user_lib, "granite-rename.elf", "user/programs/fs/rename.zig");
    const perms = user_program(b, target, optimize, user_lib, "granite-perms.elf", "user/programs/fs/perms.zig");
    const stress = user_program(b, target, optimize, user_lib, "granite-stress.elf", "user/programs/common/stress.zig");

    const flatten = host_tool(b, "flatten", "tools/flatten.zig");
    const bundle_tool = host_tool(b, "bundle", "tools/bundle.zig");
    const seedisk = host_seedisk(b);

    const kernel_image = flatten_image(b, flatten, kernel, "granite-kernel.bin");
    const flint_image = flatten_image(b, flatten, flint, "flint.bin");

    const bundle_run = b.addRunArtifact(bundle_tool);
    const bundle_image = bundle_run.addOutputFileArg("bundle.img");

    add_module(bundle_run, "flint", flint_image);
    add_artifact_module(bundle_run, "console", console);
    add_artifact_module(bundle_run, "block", block);
    add_artifact_module(bundle_run, "marble", marble);
    add_artifact_module(bundle_run, "naming", naming);
    add_artifact_module(bundle_run, "filesystem", filesystem);
    add_artifact_module(bundle_run, "echo", echo);
    add_artifact_module(bundle_run, "cat", cat);
    add_artifact_module(bundle_run, "help", help);
    add_artifact_module(bundle_run, "about", about);
    add_artifact_module(bundle_run, "hello", hello);
    add_artifact_module(bundle_run, "clear", clear);
    add_artifact_module(bundle_run, "wc", wc);
    add_artifact_module(bundle_run, "status", status);
    add_artifact_module(bundle_run, "location", location);
    add_artifact_module(bundle_run, "ls", ls);
    add_artifact_module(bundle_run, "view", view);
    add_artifact_module(bundle_run, "write", write);
    add_artifact_module(bundle_run, "create", create);
    add_artifact_module(bundle_run, "mkdir", mkdir);
    add_artifact_module(bundle_run, "delete", delete);
    add_artifact_module(bundle_run, "rename", rename);
    add_artifact_module(bundle_run, "perms", perms);
    add_artifact_module(bundle_run, "stress", stress);

    b.installArtifact(kernel);
    b.getInstallStep().dependOn(&b.addInstallBinFile(kernel_image, "granite-kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(flint_image, "flint.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(bundle_image, "bundle.img").step);

    // The persistent virtio disk: created once, then reused across runs so the filesystem survives reboots.

    const disk_path = b.pathFromRoot(if (disk == default_disk_mib) "disk.img" else b.fmt("disk-{d}M.img", .{disk}));
    const seedisk_run = b.addRunArtifact(seedisk);

    seedisk_run.addArg(disk_path);
    seedisk_run.addArg(b.fmt("{d}", .{disk_bytes}));
    add_seed_program(seedisk_run, "echo", echo);
    add_seed_program(seedisk_run, "cat", cat);
    add_seed_program(seedisk_run, "help", help);
    add_seed_program(seedisk_run, "about", about);
    add_seed_program(seedisk_run, "hello", hello);
    add_seed_program(seedisk_run, "clear", clear);
    add_seed_program(seedisk_run, "wc", wc);
    add_seed_program(seedisk_run, "status", status);
    add_seed_program(seedisk_run, "stress", stress);
    add_seed_program(seedisk_run, "location", location);
    add_seed_program(seedisk_run, "ls", ls);
    add_seed_program(seedisk_run, "view", view);
    add_seed_program(seedisk_run, "write", write);
    add_seed_program(seedisk_run, "create", create);
    add_seed_program(seedisk_run, "mkdir", mkdir);
    add_seed_program(seedisk_run, "delete", delete);
    add_seed_program(seedisk_run, "rename", rename);
    add_seed_program(seedisk_run, "perms", perms);
    seedisk_run.has_side_effects = true;

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu",
        .description = "Boot the full M7 system under QEMU `virt` with the persistent disk",
        .debug = false,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = seedisk_run },
        .smp = smp,
        .memory = memory,

    });

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-debug",
        .description = "Boot the full M7 system under QEMU `virt`, halted, with a gdb stub on :1234",
        .debug = true,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = seedisk_run },
        .smp = smp,
        .memory = memory,

    });

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-nodisk",
        .description = "Boot the full system without a disk (the filesystem reports unavailable)",
        .debug = false,
        .test_build = test_build,
        .disk = null,
        .smp = smp,
        .memory = memory,

    });

    add_qemu_step(b, kernel_image, null, .{

        .name = "qemu-bare",
        .description = "Boot the kernel without an initrd (halts after initialization)",
        .debug = false,
        .test_build = test_build,
        .disk = null,
        .smp = smp,
        .memory = memory,

    });

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

fn user_program(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    user_lib: *std.Build.Module,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {

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

};

fn add_qemu_step(b: *std.Build, kernel: std.Build.LazyPath, initrd: ?std.Build.LazyPath, step: QemuStep) void {

    const run = b.addSystemCommand(&.{

        "qemu-system-aarch64",
        "-machine", "virt,gic-version=3",
        "-cpu",     "cortex-a57",
        "-smp",     b.fmt("{d}", .{step.smp}),
        "-m",       b.fmt("{d}M", .{step.memory}),
        "-nographic",

    });

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
