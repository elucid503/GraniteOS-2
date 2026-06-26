// Common object header (06-kernel-ddd.md Section 7.1): kind + refcount driving the close-only lifecycle; M1 uses only the memory kinds.

pub const Kind = enum(u8) {

    address_space,
    region,

};

pub const Object = struct {

    kind: Kind,
    references: u32 = 1,

    pub fn retain(self: *Object) void {

        self.references += 1;

    }

    /// Drop a reference; returns true when the last one is gone and the owner should free the object.
    pub fn release(self: *Object) bool {

        self.references -= 1;
        return self.references == 0;

    }

};

const testing = @import("std").testing;

test "the last release reports the object is free" {

    var object = Object{ .kind = .region };

    object.retain();
    try testing.expectEqual(false, object.release());
    try testing.expectEqual(true, object.release());

}
