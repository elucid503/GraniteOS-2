// Fundamental address types, kept free of any arch dependency so the host-testable core never pulls in the arch layer.

pub const PhysAddr = usize;
pub const VirtAddr = usize;

// Where the DTB says the interrupt controller lives; the arch layer falls back to board constants when absent.

pub const IntctrlWindows = struct {

    distributor: PhysAddr,
    redistributor: PhysAddr,
    redistributor_stride: usize,

};

// How firmware wants secondary cores started; discovered from the DTB's /psci node on aarch64.
// x86_64 uses `.none` until INIT-SIPI bring-up lands.

pub const PowerMethod = enum {

    hvc,
    smc,
    none,

};

// What a secondary core needs before it can run Zig; the primary fills one per core and passes its
// physical address through `start_core` as the PSCI context argument.

pub const BootRecord = extern struct {

    stack_top: u64,
    core_id: u64,

};
