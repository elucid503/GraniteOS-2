// Tagged discovery blob handed to Flint in place of (or alongside) an FDT. UEFI later fills the same layout from ACPI.

pub const magic: u32 = 0x4750_4c41; // "ALPG" little-endian tag for GraniteOS platform info
pub const version: u32 = 1;

pub const UartKind = enum(u32) {

    none = 0,
    pl011 = 1,
    uart16550 = 2,

};

pub const PlatformInfo = extern struct {

    magic: u32 = magic,
    version: u32 = version,

    uart_kind: u32 = @intFromEnum(UartKind.none),
    uart_base: u64 = 0,
    uart_irq: u32 = 0,
    core_count: u32 = 1,

    reserved: u32 = 0,

};

pub fn is_platform_info(address: usize) bool {

    const header: *const PlatformInfo = @ptrFromInt(address);

    return header.magic == magic and header.version == version;

}
