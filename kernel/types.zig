// Fundamental address types, kept free of any arch dependency so the host-testable core never pulls in the arch layer.

pub const PhysAddr = usize;
pub const VirtAddr = usize;
