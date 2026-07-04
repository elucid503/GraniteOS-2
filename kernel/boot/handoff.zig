// Boot hand-off (06-kernel-ddd.md Section 13; 04-boot-and-bootstrap.md): construct the first world and spawn the Startup Binary. The kernel's only loading responsibility is this one raw-mapped, static, non-PIE image; every later program is loaded in user space.

const std = @import("std");

const arch = @import("../arch/arch.zig");
const config = @import("../config.zig");

const dtb = @import("dtb.zig");
const frames = @import("../memory/frames.zig");
const region_module = @import("../memory/region.zig");
const address_space = @import("../memory/address_space.zig");
const process_module = @import("../object/process.zig");
const memory_authority = @import("../authority/memory_authority.zig");
const interrupt_authority = @import("../authority/interrupt_authority.zig");
const device_authority = @import("../authority/device_authority.zig");

const Region = region_module.Region;
const AddressSpace = address_space.AddressSpace;
const Process = process_module.Process;
const Error = @import("../error.zig").Error;

const PhysAddr = arch.PhysAddr;
const page_size = config.page_size;

const read_only = arch.Permissions{ .read = true, .user = true };
const read_write = arch.Permissions{ .read = true, .write = true, .user = true };

// The Startup Binary is the one program allowed writable code pages: its flat image carries text, data, and the
// flatten-padded zero BSS in a single raw-mapped span (04-boot-and-bootstrap.md).

const image_permissions = arch.Permissions{ .read = true, .write = true, .execute = true, .user = true };

// The bundle's fixed handle order; user/lib/cap.zig relies on these indices.

// 0: root MemoryAuthority   1: InterruptAuthority   2: DeviceAuthority   3: DTB Region   4: boot-module Region

/// Build the first AddressSpace, raw-map the Startup Binary from the initrd, pre-load its HandleTable with the
/// capability bundle, and start its first thread. `arg` (x0) carries the DTB's byte offset into its page-aligned Region.
pub fn start(initrd: dtb.MemoryRange, dtb_address: PhysAddr) Error!void {

    const space = try AddressSpace.create();

    // The working image: a private copy of the initrd bytes at the fixed link base (config.user_space_base), so the
    // pristine module Region below stays untouched for the Startup Binary to load its children from.

    const image = try Region.create(initrd.length);
    copy_initrd(image, initrd);

    const image_base = try space.map(image, null, image_permissions);

    if (image_base != config.user_space_base) return error.Invalid;

    const stack = try Region.create(config.user_stack_pages * page_size);
    const stack_base = try space.map(stack, null, read_write);
    const stack_top = stack_base + config.user_stack_pages * page_size;

    // The capability bundle (04-boot-and-bootstrap.md): all authority plus the DTB and boot module, nothing ambient.

    const modules = try Region.create(initrd.length);
    copy_initrd(modules, initrd);

    const dtb_page = std.mem.alignBackward(PhysAddr, dtb_address, page_size);
    const dtb_top = std.mem.alignForward(PhysAddr, dtb_address + dtb.total_size(dtb_address), page_size);
    const dtb_region = try Region.wrap(dtb_page, dtb_top - dtb_page);

    const memory = try memory_authority.MemoryAuthority.create_root(frames.stats().free * page_size);
    const interrupts = try interrupt_authority.InterruptAuthority.create();
    const devices = try device_authority.DeviceAuthority.create();

    const grants = [_]process_module.Grant{

        .{ .object = &memory.header },
        .{ .object = &interrupts.header },
        .{ .object = &devices.header },
        .{ .object = &dtb_region.header },
        .{ .object = &modules.header },

    };

    const startup = try Process.spawn(space, image_base, stack_top, &grants, dtb_address - dtb_page);
    _ = startup.header.release();

}

// Fill `region` with the initrd bytes (text, data, and the flatten-padded zero BSS), zeroing any rounding slack.

fn copy_initrd(region: *Region, initrd: dtb.MemoryRange) void {

    const destination: [*]u8 = @ptrFromInt(region.base);
    const source: [*]const u8 = @ptrFromInt(initrd.base);

    @memcpy(destination[0..initrd.length], source[0..initrd.length]);
    @memset(destination[initrd.length .. region.pages * page_size], 0);

    arch.sync_instruction_cache();

}
