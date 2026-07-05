// Program entry (07-userspace-ddd.md Section 3.3). ELF programs receive argv and stream metadata through an init
// message on cap.startup_endpoint before root.main(args) runs. Flint owns its own entry.

const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

const max_args = 16;

// The supervisor endpoint this program reports its exit to, if it was granted one (M5, 07-userspace-ddd.md Section 10.4).

var supervisor: ?cap.Handle = null;
var init_flags: u64 = 0;
var init_words: [6]u64 = [_]u64{0} ** 6;
var init_cwd: []const u8 = "/";
var server_stdio: ?stream.Stream = null;
var stdout_stream: ?stream.Stream = null;

// The linker places `.text.start` first, so `_start` sits at the image base the loader enters.

pub export fn _start() linksection(".text.start") callconv(.naked) noreturn {

    asm volatile (
        \\ mov x29, xzr
        \\ mov x30, xzr
        \\ b   user_enter
    );

}

export fn user_enter() callconv(.c) noreturn {

    var argv_storage: [max_args][]const u8 = undefined;
    const args = receive_init(&argv_storage) catch exit_with(1);

    if (args.len > 0) sys.set_name(base_name(args[0])) catch {};

    supervise_via(cap.supervisor);

    const status = @import("root").main(args);

    close_runtime_streams();
    exit_with(status);

}

/// Register the endpoint a supervised program reports its exit to; its runtime then sends the death message on exit.
pub fn supervise_via(endpoint: cap.Handle) void {

    supervisor = endpoint;

}

pub fn flags() u64 {

    return init_flags;

}

pub fn word(index: usize) u64 {

    return init_words[index];

}

/// The working directory the spawner launched this program in; relative paths resolve against it (fs.zig).
pub fn cwd() []const u8 {

    return init_cwd;

}

fn base_name(path: []const u8) []const u8 {

    var index = path.len;

    while (index > 0) {

        index -= 1;

        if (path[index] == '/') return path[index + 1 ..];

    }

    return path;

}

pub fn stdin() sys.Error!stream.Stream {

    if (init_flags & proto.init.stdin_ring != 0) {

        return stream.ring(cap.stdin, cap.ring_stdin_ready);

    }

    return (try server_stream()).*;

}

pub fn stdout() sys.Error!*stream.Stream {

    if (init_flags & proto.init.stdout_ring == 0) return server_stream();

    if (stdout_stream == null) {

        stdout_stream = try stream.ring(cap.stdout, cap.ring_stdout_ready);

    }

    return &stdout_stream.?;

}

pub fn stderr() sys.Error!stream.Stream {

    if (init_flags & proto.init.stderr_ring != 0) {

        return stream.ring(cap.stderr, cap.ring_stdout_ready);

    }

    return (try server_stream()).*;

}

fn server_stream() sys.Error!*stream.Stream {

    if (server_stdio == null) {

        const endpoint = if (init_flags & proto.init.stdout_ring == 0) cap.stdout else cap.stdin;

        server_stdio = try stream.server(endpoint, cap.memory);

    }

    return &server_stdio.?;

}

fn receive_init(argv_storage: *[max_args][]const u8) sys.Error![]const []const u8 {

    var message = ipc.Message.zeroed;

    _ = try sys.receive(cap.startup_endpoint, &message);

    if (message.handle_count < 1) return error.Invalid;

    init_words = message.data;
    init_flags = message.data[2];

    const argc: usize = @intCast(message.data[0]);
    const length: usize = @intCast(message.data[1]);

    if (argc > argv_storage.len) return error.Invalid;

    const base = try sys.map(cap.self_space, message.handles[0].handle, 0, sys.read);
    const bytes: [*]const u8 = @ptrFromInt(base);

    var cursor: usize = 0;

    for (0..argc) |index| {

        const start = cursor;

        while (cursor < length and bytes[cursor] != 0) {

            cursor += 1;

        }

        if (cursor >= length) return error.Invalid;

        argv_storage[index] = bytes[start..cursor];
        cursor += 1;

    }

    // The spawner appends its working directory as one trailing string; the mapped region outlives main, so slicing it is safe.

    const cwd_start = cursor;

    while (cursor < length and bytes[cursor] != 0) {

        cursor += 1;

    }

    if (cursor > cwd_start) init_cwd = bytes[cwd_start..cursor];

    return argv_storage[0..argc];

}

fn close_runtime_streams() void {

    if (stdout_stream) |*out| {

        if (init_flags & proto.init.stdout_ring != 0) out.close();

    }

}

/// Report exit to the supervisor (a one-way death message carrying `status`, 07-userspace-ddd.md Section 10.4), then exit.
pub fn exit_with(status: u8) noreturn {

    if (supervisor) |endpoint| {

        var message = ipc.Message.zeroed;

        message.data[0] = proto.supervisor.death;
        message.data[1] = status;

        sys.send(endpoint, &message) catch {};

    }

    exit();

}

/// Exit is just close(SELF_THREAD) (03-syscall-abi.md); the guard loop is unreachable.
pub fn exit() noreturn {

    while (true) {

        sys.close(cap.self_thread) catch {};

    }

}
