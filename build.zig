// Build the aarch64 freestanding kernel, M7 user module bundle, the persistent disk image, and QEMU `virt` run steps.

const std = @import("std");

const disk_bytes = 64 * 1024 * 1024;

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{});
    const test_build = b.option(bool, "test", "Exit QEMU via semihosting on halt/panic") orelse false;

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 },

    });

    const options = b.addOptions();
    options.addOption(bool, "test", test_build);

    const kernel_module = b.createModule(.{

        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .single_threaded = true,
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
    const cat_via_name = user_program(b, target, optimize, user_lib, "granite-cat-via-name.elf", "user/programs/common/cat_via_name.zig");
    const ls = user_program(b, target, optimize, user_lib, "granite-ls.elf", "user/programs/fs/ls.zig");
    const view = user_program(b, target, optimize, user_lib, "granite-view.elf", "user/programs/fs/view.zig");
    const write = user_program(b, target, optimize, user_lib, "granite-write.elf", "user/programs/fs/write.zig");
    const create = user_program(b, target, optimize, user_lib, "granite-create.elf", "user/programs/fs/create.zig");
    const mkdir = user_program(b, target, optimize, user_lib, "granite-mkdir.elf", "user/programs/fs/mkdir.zig");
    const delete = user_program(b, target, optimize, user_lib, "granite-delete.elf", "user/programs/fs/delete.zig");
    const rename = user_program(b, target, optimize, user_lib, "granite-rename.elf", "user/programs/fs/rename.zig");

    const flatten = host_tool(b, "flatten", "tools/flatten.zig");
    const bundle_tool = host_tool(b, "bundle", "tools/bundle.zig");
    const mkdisk = host_tool(b, "mkdisk", "tools/mkdisk.zig");

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
    add_artifact_module(bundle_run, "cat-via-name", cat_via_name);
    add_artifact_module(bundle_run, "ls", ls);
    add_artifact_module(bundle_run, "view", view);
    add_artifact_module(bundle_run, "write", write);
    add_artifact_module(bundle_run, "create", create);
    add_artifact_module(bundle_run, "mkdir", mkdir);
    add_artifact_module(bundle_run, "delete", delete);
    add_artifact_module(bundle_run, "rename", rename);

    b.installArtifact(kernel);
    b.getInstallStep().dependOn(&b.addInstallBinFile(kernel_image, "granite-kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(flint_image, "flint.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(bundle_image, "bundle.img").step);

    // The persistent virtio disk: created once, then reused across runs so the filesystem survives reboots.

    const disk_path = b.pathFromRoot("disk.img");
    const mkdisk_run = b.addRunArtifact(mkdisk);

    mkdisk_run.addArg(disk_path);
    mkdisk_run.addArg(b.fmt("{d}", .{disk_bytes}));
    mkdisk_run.has_side_effects = true;

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu",
        .description = "Boot the full M7 system under QEMU `virt` with the persistent disk",
        .debug = false,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = mkdisk_run },

    });

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-debug",
        .description = "Boot the full M7 system under QEMU `virt`, halted, with a gdb stub on :1234",
        .debug = true,
        .test_build = test_build,
        .disk = .{ .path = disk_path, .prepare = mkdisk_run },

    });

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-nodisk",
        .description = "Boot the full system without a disk (the filesystem reports unavailable)",
        .debug = false,
        .test_build = test_build,
        .disk = null,

    });

    add_qemu_step(b, kernel_image, null, .{

        .name = "qemu-bare",
        .description = "Boot the kernel without an initrd (halts after initialization)",
        .debug = false,
        .test_build = test_build,
        .disk = null,

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

};

fn add_qemu_step(b: *std.Build, kernel: std.Build.LazyPath, initrd: ?std.Build.LazyPath, step: QemuStep) void {

    const run = b.addSystemCommand(&.{

        "qemu-system-aarch64",
        "-machine", "virt",
        "-cpu",     "cortex-a57",
        "-smp",     "1",
        "-m",       "256M",
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
