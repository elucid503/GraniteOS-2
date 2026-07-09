// Portable machine description filled by arch-specific discovery (DTB, Multiboot2, later UEFI).

const frames = @import("../memory/frames.zig");
const types = @import("../types.zig");

pub const MemoryRange = frames.MemoryRange;
pub const IntctrlWindows = types.IntctrlWindows;

pub const Machine = struct {

    memory: []const MemoryRange,
    core_count: usize,
    intctrl: ?IntctrlWindows,

    // Boot modules (QEMU -initrd / Multiboot2 module): the hand-off turns this into Regions.
    initrd: ?MemoryRange,

    // Per-core firmware identifiers (MPIDR on aarch64; APIC id on x86). Unused slots are ignored.
    cpus: []const u64,

    // Firmware power conduit for secondary bring-up; null means single-core only.
    power: ?types.PowerMethod,

    // Physical address of the discovery blob handed to Flint (FDT or PlatformInfo).
    discovery: types.PhysAddr,

    // Byte length of the discovery blob (FDT total size, or sizeof(PlatformInfo)).
    discovery_length: usize,

};
