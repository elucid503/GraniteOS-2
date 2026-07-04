// Handle helpers and reserved handle indices (07-userspace-ddd.md Section 3.2). A handle is `{index, generation}` transported as one non-negative word; a fresh table hands out generation-zero handles in insertion order, which is what makes the grant layouts below plain integers.

pub const Handle = u32;

// Sentinel self-handles, resolved by the kernel without a table slot (03-syscall-abi.md).

pub const self_process: Handle = 0xffff_ffff;
pub const self_thread: Handle = 0xffff_fffe;
pub const self_space: Handle = 0xffff_fffd;

// configure() attributes (03-syscall-abi.md appendix).

pub const Attribute = enum(u64) {

    scheduling_level,
    scheduling_class,
    bound_notification,

};

// scheduling_class values (kernel/sched/scheduler.zig Class).

pub const class_driver: u64 = 0;
pub const class_normal: u64 = 1;

// The Startup Binary's bootstrap bundle, in the order the kernel hand-off inserts it (kernel/boot/handoff.zig).

pub const startup = struct {

    pub const memory: Handle = 0; // root MemoryAuthority
    pub const interrupts: Handle = 1; // InterruptAuthority
    pub const devices: Handle = 2; // DeviceAuthority
    pub const dtb: Handle = 3; // read-only DTB Region
    pub const module: Handle = 4; // pristine boot-module Region (the flat user image)

};

// M4 grant layouts, in spawn order. The full reserved layout (STDIN..SUPERVISOR, 07-userspace-ddd.md Section 3.2)
// lands with M6's spawn/argv machinery; until then each program class documents its own short list here.

pub const driver = struct {

    pub const endpoint: Handle = 0; // requests arrive here
    pub const device: Handle = 1; // MMIO window Region
    pub const interrupt: Handle = 2; // the hardware line
    pub const memory: Handle = 3; // memory-authority sub-grant

};

pub const shell = struct {

    pub const console: Handle = 0; // the console driver's endpoint (badged)
    pub const memory: Handle = 1; // memory-authority sub-grant

};
