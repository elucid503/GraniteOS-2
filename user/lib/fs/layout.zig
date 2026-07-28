// Canonical on-disk directory layout for GraniteOS.

const fs = @import("fs.zig");

pub const root = "/";
pub const apps = "/apps";
pub const temp = "/temp";
pub const user = "/user";
pub const cfgs = "/cfgs";

/// Create the top-level layout; ignores errors when directories already exist.
pub fn ensure(client: *fs.Client) void {

    client.mkdir(apps) catch {};
    client.mkdir(temp) catch {};
    client.mkdir(user) catch {};
    client.mkdir(cfgs) catch {};

}
