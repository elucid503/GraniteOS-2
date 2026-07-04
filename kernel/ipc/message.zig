// The IPC message envelope (06-kernel-ddd.md Section 9; 03-syscall-abi.md): a small fixed struct that lives in the caller's memory.

const config = @import("../config.zig");

const Handle = @import("../cap/handle.zig").Handle;

// The sentinel badge `receive` returns when a bound notification (not a request) woke it (03-syscall-abi.md Multi-wait).
// It is a large positive value so it survives the signed ABI as a success (a real badge would never be this).

pub const notification_wake: u64 = 0x7fff_ffff_ffff_ffff;

// One transferred handle plus its disposition: `move` closes it in the sender, a copy leaves it in both.

pub const HandleSlot = extern struct {

    handle: Handle,
    move: bool,

};

pub const Message = extern struct {

    data: [config.message_data_words]u64,
    handles: [config.message_handle_slots]HandleSlot,

    reply: Handle, // On a received request the kernel writes the one-shot reply handle here; unused (zero) otherwise.

    handle_count: u32, // How many leading handle slots actually carry a handle. Kept in the envelope so the kernel copies only what is set.

    pub const zeroed: Message = std.mem.zeroes(Message);

};

const std = @import("std");
const testing = std.testing;

test "the envelope fits within one page so a page-aligned buffer never straddles a boundary" {

    try testing.expect(@sizeOf(Message) <= config.page_size);

}
