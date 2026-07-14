// Static network configuration.

pub var mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };

pub const ip: u32 = 0x0a00_020f; // 10.0.2.15
pub const netmask: u32 = 0xffff_ff00; // /24
pub const gateway: u32 = 0x0a00_0202; // 10.0.2.2

pub fn on_link(addr: u32) bool {

    return (addr & netmask) == (ip & netmask);

}

/// The IP whose MAC we must resolve to reach `dest`: itself if on-link, the gateway otherwise.
pub fn next_hop(dest: u32) u32 {

    return if (on_link(dest)) dest else gateway;

}
