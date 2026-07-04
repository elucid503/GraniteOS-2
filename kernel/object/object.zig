// Common object header (06-kernel-ddd.md Section 7.1): kind + refcount driving the close-only lifecycle.

pub const Kind = enum(u8) {

    process,
    thread,
    address_space,
    region,

    endpoint,
    notification,
    interrupt,

    memory_authority,
    interrupt_authority,
    device_authority,

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

// The kind-erased free path: routes a dead object back to its type's slab (used by the handle table's close).

const Process = @import("process.zig").Process;
const Thread = @import("thread.zig").Thread;
const AddressSpace = @import("../memory/address_space.zig").AddressSpace;
const Region = @import("../memory/region.zig").Region;
const Endpoint = @import("endpoint.zig").Endpoint;
const Notification = @import("notification.zig").Notification;
const Interrupt = @import("interrupt.zig").Interrupt;
const MemoryAuthority = @import("../authority/memory_authority.zig").MemoryAuthority;
const InterruptAuthority = @import("../authority/interrupt_authority.zig").InterruptAuthority;
const DeviceAuthority = @import("../authority/device_authority.zig").DeviceAuthority;

pub fn TypeOf(comptime kind: Kind) type {

    return switch (kind) {

        .process => Process,
        .thread => Thread,
        .address_space => AddressSpace,
        .region => Region,
        .endpoint => Endpoint,
        .notification => Notification,
        .interrupt => Interrupt,
        .memory_authority => MemoryAuthority,
        .interrupt_authority => InterruptAuthority,
        .device_authority => DeviceAuthority,

    };

}

pub fn destroy(object: *Object) void {

    switch (object.kind) {

        .process => container(Process, object).destroy(),
        .thread => container(Thread, object).destroy(),
        .address_space => container(AddressSpace, object).destroy(),
        .region => container(Region, object).destroy(),
        .endpoint => container(Endpoint, object).destroy(),
        .notification => container(Notification, object).destroy(),
        .interrupt => container(Interrupt, object).destroy(),
        .memory_authority => container(MemoryAuthority, object).destroy(),
        .interrupt_authority => container(InterruptAuthority, object).destroy(),
        .device_authority => container(DeviceAuthority, object).destroy(),

    }

}

// Recover the containing object; headers always sit in slab-allocated objects, so the cast holds.

pub fn container(comptime T: type, object: *Object) *T {

    const parent: *align(@alignOf(Object)) T = @fieldParentPtr("header", object);
    return @alignCast(parent);

}

const testing = @import("std").testing;

test "the last release reports the object is free" {

    var object = Object{ .kind = .region };

    object.retain();
    try testing.expectEqual(false, object.release());
    try testing.expectEqual(true, object.release());

}
