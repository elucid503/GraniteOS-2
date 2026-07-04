// Program entry (07-userspace-ddd.md Section 3.3). The kernel starts a first thread with its argument in x0 and the
// stack already loaded, so `_start` only has to establish a clean frame chain and enter Zig. Init-message/argv
// consumption lands with M6's spawn machinery; until then the argument word is passed through untouched.

const cap = @import("cap.zig");
const sys = @import("sys.zig");

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

/// Exit is just close(SELF_THREAD) (03-syscall-abi.md); the guard loop is unreachable.
pub fn exit() noreturn {

    while (true) {

        sys.close(cap.self_thread) catch {};

    }

}
