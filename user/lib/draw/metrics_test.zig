const std = @import("std");
const text = @import("text.zig");
test "metrics" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "user/fonts/JetBrainsMono-Regular.ttf", 512*1024);
    defer std.testing.allocator.free(bytes);
    const face = try text.Face.parse(bytes);
    const px: u32 = 13;
    std.debug.print("mono_w={d} mono_h={d} ascent={d} line_h={d} upem={d} asc={d} desc={d}\n", .{
        face.mono_width(px), face.mono_height(px), face.ascent_px(px), face.line_height(px),
        face.units_per_em, face.ascent, face.descent,
    });
    // simulate resize
    const usable_w: i32 = 724 - 16;
    const usable_h: i32 = 436 - 16;
    const cols = @min(@as(usize, 128), @as(usize, @intCast(@max(@as(i32, 1), @divTrunc(usable_w, face.mono_width(px))))));
    const rows = @min(@as(usize, 48), @as(usize, @intCast(@max(@as(i32, 1), @divTrunc(usable_h, face.mono_height(px))))));
    std.debug.print("grid {d}x{d}\n", .{cols, rows});
}
