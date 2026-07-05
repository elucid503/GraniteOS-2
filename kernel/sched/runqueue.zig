// Intrusive per-core run queues (06-kernel-ddd.md Section 10): threads carry their own links, so enqueueing never allocates. FIFO within a queue; the scheduler layers the level policy on top.

const Thread = @import("../object/thread.zig").Thread;

pub const Link = struct {

    next: ?*Thread = null,
    prev: ?*Thread = null,

};

pub const RunQueue = struct {

    head: ?*Thread = null,
    tail: ?*Thread = null,

    pub fn push(self: *RunQueue, thread: *Thread) void {

        thread.queue_link = .{ .next = null, .prev = self.tail };

        if (self.tail) |tail| {

            tail.queue_link.next = thread;

        } else {

            self.head = thread;

        }

        self.tail = thread;

    }

    pub fn pop(self: *RunQueue) ?*Thread {

        const thread = self.head orelse return null;

        self.remove(thread);

        return thread;

    }

    pub fn remove(self: *RunQueue, thread: *Thread) void {

        if (thread.queue_link.prev) |prev| prev.queue_link.next = thread.queue_link.next else self.head = thread.queue_link.next;
        if (thread.queue_link.next) |next| next.queue_link.prev = thread.queue_link.prev else self.tail = thread.queue_link.prev;

        thread.queue_link = .{};

    }

    pub fn is_empty(self: *const RunQueue) bool {

        return self.head == null;

    }

    pub fn count(self: *const RunQueue) u32 {

        var total: u32 = 0;
        var link = self.head;

        while (link) |thread| {

            total += 1;
            link = thread.queue_link.next;

        }

        return total;

    }

};

const testing = @import("std").testing;

test "push and pop are first-in first-out" {

    var queue = RunQueue{};

    var a: Thread = undefined;
    var b: Thread = undefined;

    a.queue_link = .{};
    b.queue_link = .{};

    queue.push(&a);
    queue.push(&b);

    try testing.expectEqual(&a, queue.pop().?);
    try testing.expectEqual(&b, queue.pop().?);
    try testing.expectEqual(@as(?*Thread, null), queue.pop());

}

test "remove unlinks from the middle" {

    var queue = RunQueue{};

    var a: Thread = undefined;
    var b: Thread = undefined;
    var c: Thread = undefined;

    a.queue_link = .{};
    b.queue_link = .{};
    c.queue_link = .{};

    queue.push(&a);
    queue.push(&b);
    queue.push(&c);

    queue.remove(&b);

    try testing.expectEqual(&a, queue.pop().?);
    try testing.expectEqual(&c, queue.pop().?);
    try testing.expect(queue.is_empty());

}
