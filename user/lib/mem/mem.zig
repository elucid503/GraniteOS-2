// Region-backed heap (07-userspace-ddd.md Section 3.6): no `brk`. The heap grows by `create`-ing Regions from the process's memory authority and mapping them; a bump pointer sub-allocates within the current chunk. Freeing arrives with a real allocator later.

const cap = @import("../cap/cap.zig");
const sys = @import("../syscall/sys.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const page_size = 4096;
const chunk_pages = 16;

pub const Heap = struct {

    authority: Handle,

    base: usize = 0,
    used: usize = 0,
    capacity: usize = 0,

    pub fn init(authority: Handle) Heap {

        return .{ .authority = authority };

    }

    /// A fresh 16-byte-aligned span of `length` bytes, growing the heap by a mapped Region when needed.
    pub fn alloc(self: *Heap, length: usize) Error![]u8 {

        self.used = align_up(self.used, 16);

        if (self.used + length > self.capacity) try self.grow(length);

        const span: [*]u8 = @ptrFromInt(self.base + self.used);
        self.used += length;

        return span[0..length];

    }

    // Map a fresh chunk and restart the bump pointer in it; the remainder of the old chunk is abandoned.

    fn grow(self: *Heap, length: usize) Error!void {

        const bytes = @max(align_up(length, page_size), chunk_pages * page_size);

        const region = try sys.create(.region, bytes, self.authority);

        self.base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
        self.used = 0;
        self.capacity = bytes;

    }

};

fn align_up(value: usize, alignment: usize) usize {

    return (value + alignment - 1) & ~(alignment - 1);

}
