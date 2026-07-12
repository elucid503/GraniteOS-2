const std = @import("std");

const lib = @import("lib");

const Rect = lib.draw.Rect;

pub const capacity: usize = 12;

pub const List = struct {

    rects: [capacity]Rect = [_]Rect{Rect.empty} ** capacity,
    len: usize = 0,

    pub fn add(self: *List, rect: Rect) void {

        if (rect.is_empty()) return;

        if (self.len < capacity) {

            self.rects[self.len] = rect;
            self.len += 1;
            return;

        }

        var best_a: usize = 0;
        var best_b: usize = 1;
        var best_cost = merge_cost(self.rects[0], self.rects[1]);

        for (0..self.len) |a| {

            for (a + 1..self.len) |b| {

                const cost = merge_cost(self.rects[a], self.rects[b]);

                if (cost < best_cost) {

                    best_a = a;
                    best_b = b;
                    best_cost = cost;

                }

            }

        }

        self.rects[best_a] = self.rects[best_a].cover(self.rects[best_b]);
        self.rects[best_b] = rect;

    }

    pub fn clear(self: *List) void {

        self.len = 0;

    }

};

fn area(rect: Rect) u64 {

    if (rect.is_empty()) return 0;

    return @as(u64, @intCast(rect.w)) * @as(u64, @intCast(rect.h));

}

fn merge_cost(a: Rect, b: Rect) u64 {

    const covered = area(a.cover(b));
    const separate = area(a) + area(b);

    return if (covered > separate) covered - separate else 0;

}

test "overflow merges the cheapest pair and preserves the new rectangle" {

    var list = List{};

    for (0..capacity) |index| {

        list.add(.{ .x = @intCast(index * 100), .y = 0, .w = 10, .h = 10 });

    }

    const newest = Rect{ .x = 7, .y = 8, .w = 9, .h = 10 };
    list.add(newest);

    try std.testing.expectEqual(capacity, list.len);

    var found = false;

    for (list.rects[0..list.len]) |rect| {

        if (std.meta.eql(rect, newest)) found = true;

    }

    try std.testing.expect(found);

}
