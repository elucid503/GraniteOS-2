// Fundamental address types, kept free of any arch dependency so the host-testable core never pulls in the arch layer.

pub const PhysAddr = usize;
pub const VirtAddr = usize;

// Where the DTB says the interrupt controller lives; the arch layer falls back to board constants when absent.

pub const IntctrlWindows = struct {

    distributor: PhysAddr,
    cpu_interface: PhysAddr,

};
