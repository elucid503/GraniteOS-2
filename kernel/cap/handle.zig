// Handle (06-kernel-ddd.md Section 8): the per-process capability reference, transported as a non-negative integer across the ABI. The generation is bumped on slot reuse to defeat ABA.

pub const Handle = packed struct(u32) {

    index: u20,
    generation: u12,

};

// Reserved sentinel handles (03-syscall-abi.md): identity without a table slot. They sit at the very top of the
// 32-bit handle space, far above any real index, so the syscall layer can recognise them before a table lookup.

pub const self_process: u32 = 0xffff_ffff;
pub const self_thread: u32 = 0xffff_fffe;
pub const self_space: u32 = 0xffff_fffd;

/// True when a raw ABI word names one of the identity sentinels rather than a table slot.
pub fn is_sentinel(raw: u32) bool {

    return raw >= self_space;

}

const testing = @import("std").testing;

test "a handle packs into one ABI word" {

    const handle = Handle{ .index = 7, .generation = 3 };
    const word: u32 = @bitCast(handle);

    const back: Handle = @bitCast(word);

    try testing.expectEqual(@as(u20, 7), back.index);
    try testing.expectEqual(@as(u12, 3), back.generation);

}
