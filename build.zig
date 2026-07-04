// Build the aarch64 freestanding kernel, the user-space Startup Binary image, and the QEMU `virt` run steps (08-roadmap.md; 06-kernel-ddd.md Section 2, 07-userspace-ddd.md Section 2, Section 11).

const std = @import("std");

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{});

    const test_build = b.option( bool, "test", "Exit QEMU via semihosting on halt/panic (for the unattended milestone tests)") orelse false;

    // ARM64 `virt`, cortex-a57: EL1 kernel, GICv2, ARM generic timer (06-kernel-ddd.md Section 1, Section 16.5).

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

    // The user-space image (07-userspace-ddd.md Section 2): the runtime library plus the Startup Binary, console
    // driver, and shell, linked as one static non-PIE image at the fixed user base (user/linker/user.ld).

    const user_lib = b.createModule(.{

        .root_source_file = b.path("user/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .pic = false,

    });

    const user_console = b.createModule(.{

        .root_source_file = b.path("user/drivers/console/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .pic = false,

    });

    user_console.addImport("lib", user_lib);

    const user_shell = b.createModule(.{

        .root_source_file = b.path("user/shell/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .pic = false,

    });

    user_shell.addImport("lib", user_lib);

    const user_startup = b.createModule(.{

        .root_source_file = b.path("user/startup/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .single_threaded = true,
        .pic = false,

    });

    user_startup.addImport("lib", user_lib);
    user_startup.addImport("console", user_console);
    user_startup.addImport("shell", user_shell);

    const startup = b.addExecutable(.{

        .name = "granite-startup.elf",
        .root_module = user_startup,

    });

    startup.setLinkerScript(b.path("user/linker/user.ld"));
    startup.entry = .{ .symbol_name = "_start" };

    // QEMU hands the DTB in x0 only for a flat image, not a bare ELF; a host tool flattens load segments faithfully
    // (objcopy drops page gaps) and pads to the memory extent so the raw-mapped BSS arrives zeroed.

    const flatten = b.addExecutable(.{

        .name = "flatten",
        .root_module = b.createModule(.{

            .root_source_file = b.path("tools/flatten.zig"),
            .target = b.graph.host,
            .optimize = .Debug,

        }),

    });

    const kernel_image = flatten_image(b, flatten, kernel, "granite-kernel.bin");
    const startup_image = flatten_image(b, flatten, startup, "granite-startup.bin");

    b.installArtifact(kernel);
    b.getInstallStep().dependOn(&b.addInstallBinFile( kernel_image, "granite-kernel.bin", ).step);
    b.getInstallStep().dependOn(&b.addInstallBinFile( startup_image, "granite-startup.bin", ).step);

    add_qemu_step(b, kernel_image, startup_image, .{

        .name = "qemu",
        .description = "Boot the full system (kernel + startup binary) under QEMU `virt`",
        .debug = false,
        .test_build = test_build,

    });

    add_qemu_step(b, kernel_image, startup_image, .{

        .name = "qemu-debug",
        .description = "Boot the full system under QEMU `virt`, halted, with a gdb stub on :1234",
        .debug = true,
        .test_build = test_build,

    });

    // The kernel alone halts after the M3 checks, so the M1-M3 smoke tests terminate via semihosting.

    add_qemu_step(b, kernel_image, null, .{

        .name = "qemu-bare",
        .description = "Boot the kernel without an initrd (halts after the M3 checks)",
        .debug = false,
        .test_build = test_build,

    });

    // Host unit tests for the arch-independent core and the user runtime (06-kernel-ddd.md cross-cutting:
    // zig test runs on the host, QEMU is for integration).

    const kernel_tests = b.addTest(.{

        .root_module = b.createModule(.{

            .root_source_file = b.path("kernel/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,

        }),

    });

    const user_tests = b.addTest(.{

        .root_module = b.createModule(.{

            .root_source_file = b.path("user/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,

        }),

    });

    const test_step = b.step("test", "Run the host unit tests for the kernel core and the user runtime");

    test_step.dependOn(&b.addRunArtifact(kernel_tests).step);
    test_step.dependOn(&b.addRunArtifact(user_tests).step);

}

fn flatten_image(b: *std.Build, flatten: *std.Build.Step.Compile, image: *std.Build.Step.Compile, name: []const u8) std.Build.LazyPath {

    const run = b.addRunArtifact(flatten);

    run.addArtifactArg(image);

    return run.addOutputFileArg(name);

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
