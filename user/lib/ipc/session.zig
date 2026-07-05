// Badge-keyed per-client sessions for the pooled/looped servers (05-server-protocol.md). Every client reaches a
// server on a badge the name service mints uniquely per lookup, so sessions are found by scanning rather than by
// indexing a fixed slot. When the table fills, the least recently used slot is reclaimed — which naturally evicts the
// sessions of clients that have already exited, since a live client refreshes its slot on every request.

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

        /// The session for `badge`, created fresh if new — reclaiming the least recently used slot when the table is
        /// full. Any buffer the reclaimed (or re-attaching) client had mapped is released first.
        pub fn open(self: *Self, badge: u64) *Session {

            if (self.find(badge)) |existing| {

                release(existing);

                return existing;

            }

            const slot = self.claim();

            release(slot);

            self.clock += 1;

            slot.* = .{

                .badge = badge,
                .used = true,
                .seq = self.clock,

            };

            return slot;

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

            slot.base = 0;
            slot.capacity = 0;
            slot.extra = .{};

        }

    };

}
