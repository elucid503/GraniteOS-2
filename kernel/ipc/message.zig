// The IPC message envelope (06-kernel-ddd.md Section 9; 03-syscall-abi.md): a small fixed struct that lives in the
// caller's memory. Bulk data never rides here - it travels as a Region handle in a slot (05-server-protocol.md).

const config = @import("../config.zig");

const Handle = @import("../cap/handle.zig").Handle;

// One transferred handle plus its disposition: `move` closes it in the sender, a copy leaves it in both.

pub const HandleSlot = extern struct {

    handle: Handle,
    move: bool,

};

pub const Message = extern struct {

    data: [config.message_data_words]u64,
    handles: [config.message_handle_slots]HandleSlot,

    // On a received request the kernel writes the one-shot reply handle here; unused (zero) otherwise.
    reply: Handle,

    // How many leading handle slots actually carry a handle. Kept in the envelope so the kernel copies only what is set.
    handle_count: u32,

    pub const zeroed: Message = std.mem.zeroes(Message);

};

const std = @import("std");
const testing = std.testing;

test "the envelope fits within one page so a page-aligned buffer never straddles a boundary" {

    try testing.expect(@sizeOf(Message) <= config.page_size);

}
