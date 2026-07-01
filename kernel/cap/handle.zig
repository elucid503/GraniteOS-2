// Handle (06-kernel-ddd.md Section 8): the per-process capability reference, transported as a non-negative integer across the ABI. The generation is bumped on slot reuse to defeat ABA.

pub const Handle = packed struct(u32) {

    index: u20,
    generation: u12,

};

const testing = @import("std").testing;

test "a handle packs into one ABI word" {

    const handle = Handle{ .index = 7, .generation = 3 };
    const word: u32 = @bitCast(handle);

    const back: Handle = @bitCast(word);

    try testing.expectEqual(@as(u20, 7), back.index);
    try testing.expectEqual(@as(u12, 3), back.generation);

}
