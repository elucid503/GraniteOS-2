// Program entry (07-userspace-ddd.md Section 3.3). The kernel starts a first thread with its argument in x0 and the
// stack already loaded, so `_start` only has to establish a clean frame chain and enter Zig. Init-message/argv
// consumption lands with M6's spawn machinery; until then the argument word is passed through untouched.

const cap = @import("cap.zig");
const sys = @import("sys.zig");
const ipc = @import("ipc.zig");
const proto = @import("proto.zig");

// The supervisor endpoint this program reports its exit to, if it was granted one (M5, 07-userspace-ddd.md Section 10.4).

var supervisor: ?cap.Handle = null;

// The linker places `.text.start` first, so `_start` sits at the image base the kernel raw-maps and enters.

pub export fn _start() linksection(".text.start") callconv(.naked) noreturn {

    asm volatile (
        \\ mov x29, xzr
        \\ mov x30, xzr
        \\ b   user_enter
    );

}

export fn user_enter(arg: u64) callconv(.c) noreturn {

    @import("root").main(arg);

}

/// Register the endpoint a supervised program reports its exit to; its runtime then sends the death message on exit.
pub fn supervise_via(endpoint: cap.Handle) void {

    supervisor = endpoint;

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
