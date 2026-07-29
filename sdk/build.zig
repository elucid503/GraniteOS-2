const std = @import("std");

pub fn build(b: *std.Build) void {

    const optimize: std.builtin.OptimizeMode = if (b.option(bool, "debug", "Build with debug information") orelse false) .Debug else .ReleaseSmall;
    const source = b.option([]const u8, "source", "App source relative to the SDK directory") orelse "example/app.zig";
    const name = b.option([]const u8, "name", "Output package ID") orelse "hello-granite";

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 },

    });

    const options = b.addOptions();

    options.addOption(bool, "test", false);
    options.addOption(bool, "debug_syscall_trace", false);
    options.addOption(i64, "build_epoch_s", std.time.timestamp());

    const granite = b.createModule(.{

        .root_source_file = b.path("../user/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
        .pic = false,

    });

    granite.addImport("build_options", options.createModule());

    const app = b.createModule(.{

        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .single_threaded = false,
        .pic = false,
        .strip = optimize != .Debug,

    });

    app.addImport("granite", granite);
    app.addImport("lib", granite);

    const executable = b.addExecutable(.{

        .name = name,
        .root_module = app,

    });

    executable.setLinkerScript(b.path("../user/linker/user.ld"));
    executable.entry = .{ .symbol_name = "_start" };

    b.installArtifact(executable);

}
