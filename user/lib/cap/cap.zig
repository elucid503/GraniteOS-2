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

// The sentinel badge `receive` returns when the wake came from a bound notification, not a request (03-syscall-abi.md
// Multi-wait). Matches the kernel's `message.notification_wake`: a large positive value, so it survives the signed ABI.

pub const notification_wake: u64 = 0x7fff_ffff_ffff_ffff;

// scheduling_class values (kernel/sched/scheduler.zig Class).

pub const class_driver: u64 = 0;
pub const class_normal: u64 = 1;

// Flint's bootstrap bundle, in the order the kernel hand-off inserts it (kernel/boot/handoff.zig).

pub const flint = struct {

    pub const memory: Handle = 0; // root MemoryAuthority
    pub const interrupts: Handle = 1; // InterruptAuthority
    pub const devices: Handle = 2; // DeviceAuthority
    pub const dtb: Handle = 3; // read-only DTB Region
    pub const module: Handle = 4; // read-only module bundle Region
    pub const dma: Handle = 5; // DmaAuthority (M7)

};

// M6 reserved grant layout (07-userspace-ddd.md Section 3.2). Spawners fill these first, in order, so every program
// can start before it has dynamic discovery.

pub const stdin: Handle = 0;
pub const stdout: Handle = 1;
pub const stderr: Handle = 2;
pub const name_service: Handle = 3;
pub const memory: Handle = 4;
pub const startup_endpoint: Handle = 5;
pub const supervisor: Handle = 6;

pub const reserved_grants = 7;

// Ring streams use the STDIN/STDOUT slots for the shared Region and these tail slots for the Notification.

pub const ring_stdin_ready: Handle = 7;
pub const ring_stdout_ready: Handle = 8;

// Per-class names for extra tail grants.

pub const driver = struct {

    pub const endpoint: Handle = stdin; // requests arrive here
    pub const device: Handle = reserved_grants; // MMIO window Region
    pub const interrupt: Handle = reserved_grants + 1; // the hardware line
    pub const dma: Handle = reserved_grants + 2; // DmaAuthority sub-grant (DMA-capable drivers only)

};

pub const marble = struct {

    pub const console: Handle = stdin; // the console driver's endpoint (badged)
    pub const bundle: Handle = reserved_grants + 2; // read-only module bundle Region

};

pub const server = struct {

    pub const endpoint: Handle = stdin;

};

pub const filesystem = struct {

    pub const block: Handle = reserved_grants; // badged endpoint to the block driver

};

// The input server owns every virtio-input transport at once (in-process drivers, 07-userspace-ddd.md
// Section 12.4): init word 3 carries the device count `n`, the windows sit at `devices..devices+n`, the
// matching interrupts at `devices+n..devices+2n`, the DmaAuthority sub-grant follows at `devices+2n`,
// and init word 4 packs each transport's in-page offset as 16 bits per device.

pub const input = struct {

    pub const devices: Handle = reserved_grants;

    pub fn dma(count: usize) Handle {

        return @intCast(devices + 2 * count);

    }

};

pub const compositor = struct {

    pub const display: Handle = reserved_grants; // badged endpoint to the display driver
    pub const input: Handle = reserved_grants + 1; // badged endpoint to the input server
    pub const bundle: Handle = reserved_grants + 2; // read-only module bundle Region (fonts ride in it)

};

// GUI clients reach the compositor through the name service; their one extra grant is the bundle the
// fonts load from.

pub const gui = struct {

    pub const bundle: Handle = reserved_grants;

};
