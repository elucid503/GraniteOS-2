// Host-test stand-in for the target runtime entry.

const cap = @import("../cap/cap.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

pub fn supervise_via(_: cap.Handle) void {}

pub fn exit_with(_: u8) noreturn {

    @panic("target-only");

}

pub fn exit() noreturn {

    @panic("target-only");

}

pub fn flags() u64 {

    return 0;

}

pub fn word(_: usize) u64 {

    return 0;

}

pub fn stdin() sys.Error!stream.Stream {

    return error.Invalid;

}

pub fn stdout() sys.Error!*stream.Stream {

    return error.Invalid;

}

pub fn stderr() sys.Error!stream.Stream {

    return error.Invalid;

}
