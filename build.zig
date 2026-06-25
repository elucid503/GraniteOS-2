// Build the aarch64 freestanding kernel and the QEMU `virt` run steps (08-roadmap.md M0; 06-kernel-ddd.md Section 2).

const std = @import("std");

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{});

    const test_build = b.option( bool, "test", "Exit QEMU via semihosting after the M0 fault (for the unattended m0 test)") orelse false;

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

    const kernel = b.addExecutable(.{

        .name = "granite-kernel.elf",
        .root_module = kernel_module,

    });

    kernel.setLinkerScript(b.path("kernel/arch/aarch64/asm/linker.ld"));
    kernel.entry = .{ .symbol_name = "_start" };

    // QEMU hands the DTB in x0 only for a flat image, not a bare ELF; a host tool flattens load segments faithfully (objcopy drops page gaps).

    const flatten = b.addExecutable(.{

        .name = "flatten",
        .root_module = b.createModule(.{

            .root_source_file = b.path("tools/flatten.zig"),
            .target = b.graph.host,
            .optimize = .Debug,

        }),

    });

    const flatten_run = b.addRunArtifact(flatten);
    flatten_run.addArtifactArg(kernel);
    const kernel_image = flatten_run.addOutputFileArg("granite-kernel.bin");

    b.installArtifact(kernel);
    b.getInstallStep().dependOn(&b.addInstallBinFile( kernel_image, "granite-kernel.bin", ).step);

    add_qemu_step(b, kernel_image, .{

        .name = "qemu",
        .description = "Boot the kernel under QEMU `virt`",
        .debug = false,
        .test_build = test_build,

    });

    add_qemu_step(b, kernel_image, .{

        .name = "qemu-debug",
        .description = "Boot under QEMU `virt`, halted, with a gdb stub on :1234",
        .debug = true,
        .test_build = test_build,

    });

}

const QemuStep = struct {

    name: []const u8,
    description: []const u8,
    debug: bool,
    test_build: bool,

};

fn add_qemu_step(b: *std.Build, image: std.Build.LazyPath, step: QemuStep) void {

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
    run.addFileArg(image);

    b.step(step.name, step.description).dependOn(&run.step);

}
