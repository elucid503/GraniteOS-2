// Handle helpers and reserved grant indices; generation-zero handles in insertion order keep layouts as plain integers.

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

// Sentinel receive badge for notification wake (not a request); large positive so it survives the signed ABI.

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

// M6 reserved grants: spawners fill these first so every program can start without dynamic discovery.

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

// Input server grant layout: n MMIO windows, n interrupts, DMA sub-grant, per-device offsets packed in init word 4.

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

// GUI grant layout: compositor via name service plus bundle Region for fonts.

pub const gui = struct {

    pub const bundle: Handle = reserved_grants;

};

// Launcher server grants: endpoint in stdio slots, console for GUI children, bundle for program images.

pub const launcher = struct {

    pub const endpoint: Handle = stdin; // spawn requests arrive here
    pub const console: Handle = reserved_grants; // the console endpoint passed on to GUI children
    pub const bundle: Handle = reserved_grants + 1; // read-only module bundle Region

};

// virtio-net driver: the same MMIO + interrupt + DMA-sub-grant layout as the block/audio drivers.

pub const net_driver = struct {

    pub const endpoint: Handle = stdin;
    pub const device: Handle = reserved_grants; // MMIO window Region
    pub const interrupt: Handle = reserved_grants + 1; // the hardware line
    pub const dma: Handle = reserved_grants + 2; // DmaAuthority sub-grant

};

// The netstack server: its own service endpoint in the standard slot, plus a badged endpoint to the net driver.

pub const netstack = struct {

    pub const net: Handle = reserved_grants; // badged endpoint to the virtio-net driver

};
