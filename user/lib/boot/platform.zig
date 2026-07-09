// Tagged discovery blob handed to Flint (mirrors kernel/boot/platform.zig).

pub const magic: u32 = 0x4750_4c41;
pub const version: u32 = 1;

pub const UartKind = enum(u32) {

    none = 0,
    pl011 = 1,
    uart16550 = 2,

};

pub const PlatformInfo = extern struct {

    magic: u32,
    version: u32,
    uart_kind: u32,
    uart_base: u64,
    uart_irq: u32,
    core_count: u32,
    reserved: u32,

};

pub fn is_platform_info(address: usize) bool {

    const header: *const PlatformInfo = @ptrFromInt(address);

    return header.magic == magic and header.version == version;

}

pub fn read(address: usize) ?PlatformInfo {

    if (!is_platform_info(address)) return null;

    return @as(*const PlatformInfo, @ptrFromInt(address)).*;

}
