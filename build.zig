// Build the aarch64 freestanding kernel, M6 user module bundle, and QEMU `virt` run steps.

const std = @import("std");

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

    const user_lib = b.createModule(.{

        .root_source_file = b.path("user/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .pic = false,

    });

    const startup = user_program(b, target, optimize, user_lib, "granite-startup.elf", "user/startup/main.zig");
    const console = user_program(b, target, optimize, user_lib, "granite-console.elf", "user/drivers/console/main.zig");
    const marble = user_program(b, target, optimize, user_lib, "granite-marble.elf", "user/marble/main.zig");
    const naming = user_program(b, target, optimize, user_lib, "granite-naming.elf", "user/servers/naming/main.zig");
    const echo = user_program(b, target, optimize, user_lib, "granite-echo.elf", "user/programs/echo.zig");
    const cat = user_program(b, target, optimize, user_lib, "granite-cat.elf", "user/programs/cat.zig");
    const help = user_program(b, target, optimize, user_lib, "granite-help.elf", "user/programs/help.zig");
    const cat_via_name = user_program(b, target, optimize, user_lib, "granite-cat-via-name.elf", "user/programs/cat_via_name.zig");

    const flatten = host_tool(b, "flatten", "tools/flatten.zig");
    const bundle_tool = host_tool(b, "bundle", "tools/bundle.zig");

    const kernel_image = flatten_image(b, flatten, kernel, "granite-kernel.bin");
    const startup_image = flatten_image(b, flatten, startup, "startup.bin");
    const bundle_image = bundle_image_step(b, bundle_tool, .{

        .startup = startup_image,
        .console = console,
        .marble = marble,
        .naming = naming,
        .echo = echo,
        .cat = cat,
        .help = help,
        .cat_via_name = cat_via_name,

    });

    b.installArtifact(kernel);
    b.getInstallStep().dependOn(&b.addInstallBinFile(kernel_image, "granite-kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(startup_image, "startup.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(bundle_image, "bundle.img").step);

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu",
        .description = "Boot the full M6 system under QEMU `virt`",
        .debug = false,
        .test_build = test_build,

    });

    add_qemu_step(b, kernel_image, bundle_image, .{

        .name = "qemu-debug",
        .description = "Boot the full M6 system under QEMU `virt`, halted, with a gdb stub on :1234",
        .debug = true,
        .test_build = test_build,

    });

    add_qemu_step(b, kernel_image, null, .{

        .name = "qemu-bare",
        .description = "Boot the kernel without an initrd (halts after initialization)",
        .debug = false,
        .test_build = test_build,

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
        .single_threaded = true,
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

const BundleInputs = struct {

    startup: std.Build.LazyPath,
    console: *std.Build.Step.Compile,
    marble: *std.Build.Step.Compile,
    naming: *std.Build.Step.Compile,
    echo: *std.Build.Step.Compile,
    cat: *std.Build.Step.Compile,
    help: *std.Build.Step.Compile,
    cat_via_name: *std.Build.Step.Compile,

};

fn bundle_image_step(b: *std.Build, bundle_tool: *std.Build.Step.Compile, inputs: BundleInputs) std.Build.LazyPath {

    const run = b.addRunArtifact(bundle_tool);

    const output = run.addOutputFileArg("bundle.img");

    add_module(run, "startup", inputs.startup);
    add_artifact_module(run, "console", inputs.console);
    add_artifact_module(run, "marble", inputs.marble);
    add_artifact_module(run, "naming", inputs.naming);
    add_artifact_module(run, "echo", inputs.echo);
    add_artifact_module(run, "cat", inputs.cat);
    add_artifact_module(run, "help", inputs.help);
    add_artifact_module(run, "cat-via-name", inputs.cat_via_name);

    return output;

}

fn add_module(run: *std.Build.Step.Run, name: []const u8, file: std.Build.LazyPath) void {

    run.addArg(name);
    run.addFileArg(file);

}

fn add_artifact_module(run: *std.Build.Step.Run, name: []const u8, artifact: *std.Build.Step.Compile) void {

    run.addArg(name);
    run.addArtifactArg(artifact);

}

const QemuStep = struct {

    name: []const u8,
    description: []const u8,
    debug: bool,
    test_build: bool,

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

    b.step(step.name, step.description).dependOn(&run.step);

}
