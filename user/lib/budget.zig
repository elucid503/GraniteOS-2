// Launcher GUI pool: children charge per Region so freed memory returns on exit, not a fixed upfront slice.

pub const launcher_pool = 80 * 1024 * 1024;