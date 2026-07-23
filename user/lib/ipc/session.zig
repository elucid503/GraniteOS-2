// Badge-keyed session table with LRU reclaim; live clients refresh on each request, dead ones age out.

const cap = @import("../cap/cap.zig");
const sys = @import("../syscall/sys.zig");

/// A table of `capacity` sessions, each carrying the shared buffer plus a server-specific `Extra` payload.
pub fn Sessions(comptime Extra: type, comptime capacity: usize) type {

    return struct {

        const Self = @This();

        pub const Session = struct {

            badge: u64 = 0,
            used: bool = false,
            seq: u64 = 0,

            base: usize = 0,
            capacity: usize = 0,

            extra: Extra = .{},

        };

        slots: [capacity]Session = [_]Session{.{}} ** capacity,
        clock: u64 = 0,

        /// The live session for `badge`, touched as most-recently-used, or null if the client has not attached yet.
        pub fn find(self: *Self, badge: u64) ?*Session {

            for (&self.slots) |*slot| {

                if (slot.used and slot.badge == badge) {

                    self.clock += 1;
                    slot.seq = self.clock;

                    return slot;

                }

            }

            return null;

        }

        /// Open or create a session for badge, LRU-evicting and unmapping any reclaimed buffer first.
        pub fn open(self: *Self, badge: u64) *Session {

            if (self.find(badge)) |existing| {

                // Drop protocol state (TCP/DNS waiters, open files, ...) before rebinding the buffer.
                evict(existing);

                self.clock += 1;

                existing.* = .{

                    .badge = badge,
                    .used = true,
                    .seq = self.clock,

                };

                return existing;

            }

            const slot = self.claim();

            if (slot.used) {

                evict(slot);

            } else {

                release(slot);

            }

            self.clock += 1;

            slot.* = .{

                .badge = badge,
                .used = true,
                .seq = self.clock,

            };

            return slot;

        }

        pub fn close(self: *Self, badge: u64) void {

            for (&self.slots) |*slot| {

                if (!slot.used or slot.badge != badge) continue;

                evict(slot);
                slot.* = .{};
                return;

            }

        }

        fn claim(self: *Self) *Session {

            var victim: *Session = &self.slots[0];

            for (&self.slots) |*slot| {

                if (!slot.used) return slot;
                if (slot.seq < victim.seq) victim = slot;

            }

            return victim;

        }

        fn release(slot: *Session) void {

            if (slot.base != 0) {

                sys.unmap(cap.self_space, slot.base) catch {};

            }

            if (@hasDecl(Extra, "release")) {

                Extra.release(&slot.extra);

            }

            slot.base = 0;
            slot.capacity = 0;
            slot.extra = .{};

        }

        fn evict(slot: *Session) void {

            if (@hasDecl(Extra, "evict")) {

                Extra.evict(&slot.extra, slot.badge);

            }

            release(slot);

        }

    };

}
