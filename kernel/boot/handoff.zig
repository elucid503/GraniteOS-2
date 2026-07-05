// Boot hand-off (06-kernel-ddd.md Section 13; 04-boot-and-bootstrap.md): construct the first world and spawn Flint. The kernel's only loading responsibility is this one raw-mapped, static, non-PIE image; every later program is loaded in user space.

const std = @import("std");

const arch = @import("../arch/arch.zig");
const config = @import("../config.zig");

const dtb = @import("dtb.zig");
const bundle_module = @import("bundle.zig");
const frames = @import("../memory/frames.zig");
const region_module = @import("../memory/region.zig");
const address_space = @import("../memory/address_space.zig");
const process_module = @import("../object/process.zig");
const memory_authority = @import("../authority/memory_authority.zig");
const interrupt_authority = @import("../authority/interrupt_authority.zig");
const device_authority = @import("../authority/device_authority.zig");
const dma_authority = @import("../authority/dma_authority.zig");

const Region = region_module.Region;
const AddressSpace = address_space.AddressSpace;
const Process = process_module.Process;
const Error = @import("../error.zig").Error;

const PhysAddr = arch.PhysAddr;
const page_size = config.page_size;

const read_only = arch.Permissions{ .read = true, .user = true };
const read_write = arch.Permissions{ .read = true, .write = true, .user = true };

// Flint is the one program allowed writable code pages: its flat image carries text, data, and the flatten-padded zero
// BSS in a single raw-mapped span (04-boot-and-bootstrap.md).

const image_permissions = arch.Permissions{ .read = true, .write = true, .execute = true, .user = true };

// The bundle's fixed handle order; user/lib/cap/cap.zig relies on these indices.

// 0: root MemoryAuthority   1: InterruptAuthority   2: DeviceAuthority   3: DTB Region   4: boot-module Region
// 5: DmaAuthority

/// Build the first AddressSpace, raw-map Flint from the initrd, pre-load its HandleTable with the capability bundle,
/// and start its first thread. `arg` (x0) carries the DTB's byte offset into its page-aligned Region.
pub fn start(initrd: dtb.MemoryRange, dtb_address: PhysAddr) Error!void {

    const space = try AddressSpace.create();
    const initrd_bytes: [*]const u8 = @ptrFromInt(initrd.base);
    const bundle = try bundle_module.Bundle.open(initrd_bytes[0..initrd.length]);
    const flint_image = (try bundle.find("flint")) orelse return error.Invalid;

    // Working copy at the fixed link base (config.user_space_base); the pristine bundle Region stays untouched for Flint and Marble.

    const image = try Region.create(flint_image.len);
    copy_bytes(image, flint_image);

    const image_base = try space.map(image, null, image_permissions);

    if (image_base != config.user_space_base) return error.Invalid;

    const stack = try Region.create(config.user_stack_pages * page_size);
    const stack_base = try space.map(stack, null, read_write);
    const stack_top = stack_base + config.user_stack_pages * page_size;

    // The capability bundle (04-boot-and-bootstrap.md): all authority plus the DTB and boot module, nothing ambient.

    const module_page = std.mem.alignBackward(PhysAddr, initrd.base, page_size);
    const module_top = std.mem.alignForward(PhysAddr, initrd.base + initrd.length, page_size);
    const modules = try Region.wrap(module_page, module_top - module_page);

    const dtb_page = std.mem.alignBackward(PhysAddr, dtb_address, page_size);
    const dtb_top = std.mem.alignForward(PhysAddr, dtb_address + dtb.total_size(dtb_address), page_size);
    const dtb_region = try Region.wrap(dtb_page, dtb_top - dtb_page);

    const memory = try memory_authority.MemoryAuthority.create_root(frames.stats().free * page_size);
    const interrupts = try interrupt_authority.InterruptAuthority.create();
    const devices = try device_authority.DeviceAuthority.create();
    const dma = try dma_authority.DmaAuthority.create();

    const grants = [_]process_module.Grant{

        .{ .object = &memory.header },
        .{ .object = &interrupts.header },
        .{ .object = &devices.header },
        .{ .object = &dtb_region.header },
        .{ .object = &modules.header },
        .{ .object = &dma.header },

    };

    const module_offset = initrd.base - module_page;
    const flint_arg =
        (@as(u64, @intCast(initrd.length)) << 32) |
        (@as(u64, @intCast(module_offset)) << 16) |
        (dtb_address - dtb_page);
    const flint = try Process.spawn(space, image_base, stack_top, &grants, flint_arg);
    flint.set_name("flint");
    _ = flint.header.release();

}

fn copy_bytes(region: *Region, bytes: []const u8) void {

    const destination: [*]u8 = @ptrFromInt(region.base);

    @memcpy(destination[0..bytes.len], bytes);
    @memset(destination[bytes.len .. region.pages * page_size], 0);

    arch.sync_instruction_cache();

}
