// GUI memory for the launcher (07-userspace-ddd.md Section 11). GUI children draw from one shared pool and are
// charged per Region allocation, so closing an app returns what it actually used instead of a fixed upfront slice.

pub const launcher_pool = 80 * 1024 * 1024;