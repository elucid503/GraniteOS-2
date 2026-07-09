// Panic-only debug console (06-kernel-ddd.md Section 14): polled, not a service - the real console is a user driver.

const arch = @import("../arch/arch.zig");
const spinlock = @import("../sync/spinlock.zig");

// Serializes whole prints across cores; a panicking core seizes the console instead, so a peer
// holding the lock mid-print can never wedge the diagnostic.

var lock: spinlock.SpinLock = .{};
var panicking: bool = false;

/// The panic path takes the console unconditionally from here on (and halts the other cores anyway).
pub fn seize_for_panic() void {

    @atomicStore(bool, &panicking, true, .seq_cst);

}

fn guarded() bool {

    return !@atomicLoad(bool, &panicking, .seq_cst);

}

pub fn debug_putchar(byte: u8) void {

    arch.debug_putchar(byte);

}

pub fn debug_print(text: []const u8) void {

    const serialize = guarded();
    const saved = if (serialize) lock.acquire() else undefined;

    for (text) |byte| {

        // Serial terminals expect a carriage return before the line feed.

        if (byte == '\n') {

            debug_putchar('\r');

        }

        debug_putchar(byte);

    }

    if (serialize) lock.release(saved);

}

pub fn debug_print_dec(value: u64) void {

    var buffer: [20]u8 = undefined;
    var length: usize = 0;
    var remaining = value;

    if (remaining == 0) {

        debug_putchar('0');
        return;

    }

    while (remaining > 0) {

        buffer[length] = @intCast('0' + (remaining % 10));
        length += 1;
        remaining /= 10;

    }

    while (length > 0) {

        length -= 1;
        debug_putchar(buffer[length]);

    }

}

/// Print a 64-bit value as `0x`-prefixed, zero-padded hex - the one number format the fault diagnostics need.
pub fn debug_print_hex(value: u64) void {

    const digits = "0123456789abcdef";

    debug_print("0x");

    var shift: u6 = 60;

    while (true) : (shift -= 4) {

        const nibble: usize = @intCast((value >> shift) & 0xf);
        debug_putchar(digits[nibble]);

        if (shift == 0) {

            break;

        }

    }

}
