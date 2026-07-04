// The GraniteOS user runtime - our "std" (07-userspace-ddd.md Section 3). Every user program links exactly this.

const builtin = @import("builtin");

pub const start = if (builtin.target.cpu.arch == .aarch64) @import("start.zig") else @import("host_start.zig");
pub const sys = @import("sys.zig");
pub const cap = @import("cap.zig");
pub const ipc = @import("ipc.zig");
pub const proto = @import("proto.zig");
pub const mem = @import("mem.zig");
pub const dtb = @import("dtb.zig");
pub const bundle = @import("bundle.zig");
pub const elf = @import("elf.zig");
pub const stream = @import("stream.zig");
pub const io = @import("io.zig");
pub const catalog = @import("catalog.zig");
