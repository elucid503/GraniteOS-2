// Secondary-core bring-up stub for the single-core x86 pass (INIT-SIPI deferred).

const types = @import("../../types.zig");
const Error = @import("../../error.zig").Error;

pub fn start_core(method: types.PowerMethod, target: u64, record: *const types.BootRecord) Error!void {

    _ = method;
    _ = target;
    _ = record;

    return error.Invalid;

}
