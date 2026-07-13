// QEMU fw_cfg MMIO (virt: data@0, selector@8, dma@0x10). Matches EDK2 QemuFwCfgLibMmio:
// PIO select + byte/word data reads; DMA writes use a single BE64 doorbell on aarch64.

const std = @import("std");

pub const selector_signature: u16 = 0x0000;
pub const selector_file_dir: u16 = 0x0019;

pub const dma_ctl_error: u32 = 0x01;
pub const dma_ctl_read: u32 = 0x02;
pub const dma_ctl_select: u32 = 0x08;
pub const dma_ctl_write: u32 = 0x10;

pub const ramfb_name = "etc/ramfb";

/// DRM_FORMAT_XRGB8888 — little-endian x:R:G:B matches proto.display.format_xrgb.
pub const fourcc_xrgb8888: u32 = std.mem.readInt(u32, "XR24", .little);

pub const File = extern struct {

    size: u32,
    select: u16,
    reserved: u16,
    name: [56]u8,

};

pub const DmaAccess = extern struct {

    control: u32,
    length: u32,
    address: u64,

};

/// QEMU `QEMU_PACKED` RAMFBCfg is exactly 28 bytes (no C trailing pad).
pub fn writeRamfbCfg(
    fw: *const FwCfg,
    selector: u16,
    addr: u64,
    fourcc: u32,
    width: u32,
    height: u32,
    stride: u32,
) !void {

    var bytes: [28]u8 = undefined;

    std.mem.writeInt(u64, bytes[0..8], addr, .big);
    std.mem.writeInt(u32, bytes[8..12], fourcc, .big);
    std.mem.writeInt(u32, bytes[12..16], 0, .big); // flags
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    std.mem.writeInt(u32, bytes[24..28], stride, .big);

    try fw.write(selector, &bytes);

}

pub const FwCfg = struct {

    regs: usize,
    dma_va: usize,
    dma_pa: u64,

    pub fn init(regs: usize, dma_va: usize, dma_pa: u64) FwCfg {

        return .{ .regs = regs, .dma_va = dma_va, .dma_pa = dma_pa };

    }

    pub fn present(self: *const FwCfg) bool {

        self.select(selector_signature);

        // EDK2 uses a 32-bit data read; bytes spell "QEMU" in memory order.
        const word: *volatile u32 = @ptrFromInt(self.regs);
        const signature = word.*;

        return signature == std.mem.readInt(u32, "QEMU", .little);

    }

    pub fn find(self: *const FwCfg, name: []const u8) ?u16 {

        if (!self.present()) return null;

        self.select(selector_file_dir);

        const count = std.mem.bigToNative(u32, read_u32(self.regs));
        if (count == 0 or count > 512) return null;

        var index: u32 = 0;

        while (index < count) : (index += 1) {

            const size = read_u32(self.regs);
            const file_select = read_u16(self.regs);
            _ = read_u16(self.regs); // reserved
            _ = size;

            var filename: [56]u8 = undefined;
            read_bytes(self.regs, &filename);

            if (std.mem.eql(u8, cstring(&filename), name)) {

                return std.mem.bigToNative(u16, file_select);

            }

        }

        return null;

    }

    /// Write `bytes` to an fw_cfg file. Selects via PIO, transfers via DMA (required for writes).
    pub fn write(self: *const FwCfg, selector: u16, bytes: []const u8) !void {

        if (bytes.len == 0 or bytes.len > 2048) return error.Invalid;

        self.select(selector);
        try self.dma_transfer(dma_ctl_write, bytes);

    }

    fn select(self: *const FwCfg, key: u16) void {

        write_be16(self.regs + 8, key);
        barrier();

    }

    fn dma_transfer(self: *const FwCfg, control: u32, bytes: []const u8) !void {

        const access: *volatile DmaAccess = @ptrFromInt(self.dma_va);
        const payload: [*]u8 = @ptrFromInt(self.dma_va + 64);

        @memcpy(payload[0..bytes.len], bytes);

        access.control = std.mem.nativeToBig(u32, control);
        access.length = std.mem.nativeToBig(u32, @intCast(bytes.len));
        access.address = std.mem.nativeToBig(u64, self.dma_pa + 64);

        barrier();

        // aarch64: one BE64 write to the DMA register fires the transfer (EDK2 DmaTransferBytes).
        const doorbell: *volatile u64 = @ptrFromInt(self.regs + 0x10);
        doorbell.* = std.mem.nativeToBig(u64, self.dma_pa);

        var spins: usize = 0;

        while (spins < 1_000_000) : (spins += 1) {

            barrier();

            const status = std.mem.bigToNative(u32, access.control);

            if (status & dma_ctl_error != 0) return error.Invalid;
            if (status == 0) return;

        }

        return error.Gone;

    }

};

fn cstring(bytes: []const u8) []const u8 {

    var length: usize = 0;

    while (length < bytes.len and bytes[length] != 0) : (length += 1) {}

    return bytes[0..length];

}

fn read_bytes(data_reg: usize, bytes: []u8) void {

    const data: *volatile u8 = @ptrFromInt(data_reg);

    for (bytes) |*byte| byte.* = data.*;

}

fn read_u16(data_reg: usize) u16 {

    var buf: [2]u8 = undefined;
    read_bytes(data_reg, &buf);

    return std.mem.readInt(u16, &buf, .little);

}

fn read_u32(data_reg: usize) u32 {

    const data: *volatile u32 = @ptrFromInt(data_reg);

    return data.*;

}

fn write_be16(addr: usize, value: u16) void {

    const register: *volatile u16 = @ptrFromInt(addr);

    register.* = std.mem.nativeToBig(u16, value);

}

fn barrier() void {

    asm volatile ("dsb sy" ::: .{ .memory = true });

}
