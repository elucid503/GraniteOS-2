// The GraniteOS user runtime - our "std" (07-userspace-ddd.md Section 3). Every user program links exactly this.

const builtin = @import("builtin");

pub const start = if (builtin.target.cpu.arch == .aarch64) @import("runtime/start.zig") else @import("runtime/host_start.zig");
pub const sys = @import("syscall/sys.zig");
pub const cap = @import("cap/cap.zig");
pub const ipc = @import("ipc/ipc.zig");
pub const proto = @import("ipc/proto.zig");
pub const session = @import("ipc/session.zig");
pub const mem = @import("mem/mem.zig");
pub const dtb = @import("boot/dtb.zig");
pub const bundle = @import("boot/bundle.zig");
pub const elf = @import("boot/elf.zig");
pub const stream = @import("io/stream.zig");
pub const gfx = @import("gfx/gfx.zig");
pub const font = @import("gfx/font.zig");
pub const ttf = @import("gfx/ttf.zig");
pub const svg = @import("gfx/svg.zig");
pub const ui = @import("gfx/ui.zig");
pub const icons = @import("gfx/icons.zig");
pub const desktop = @import("gfx/desktop.zig");
pub const events = @import("gfx/events.zig");
pub const window = @import("gfx/window.zig");
pub const keymap = @import("keymap.zig");
pub const fs = @import("fs/fs.zig");
pub const sysinfo = @import("sysinfo.zig");
pub const time = @import("time.zig");
pub const io = @import("io/io.zig");
pub const term = @import("io/term.zig");
pub const log = @import("io/log.zig");
pub const catalog = @import("shell/catalog.zig");
pub const line = @import("shell/line.zig");
