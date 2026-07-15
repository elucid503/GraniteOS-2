// GUI boot helpers: retry compositor lookup at startup and open fonts from the module bundle grant.

const builtin = @import("builtin");

const cap = @import("../cap/cap.zig");
const bundle_mod = @import("../boot/bundle.zig");
const sys = @import("../syscall/sys.zig");

const ttf = @import("../draw/text.zig");
const window = @import("window.zig");

const time = @import("../time.zig");

const start = if (builtin.target.cpu.arch == .aarch64) @import("../runtime/start.zig") else @import("../runtime/host_start.zig");

const Error = sys.Error;

/// Resolve and connect to the compositor, retrying briefly while it is still registering its name.
pub fn connect(authority: cap.Handle) Error!window.Connection {

    var attempts: usize = 0;
    var delay_ms: u64 = 5;

    while (true) {

        return window.Connection.connect(authority) catch |failure| {

            attempts += 1;

            if (attempts > 200) return failure;

            // Sleep rather than spin between attempts: the compositor is only briefly unregistered at boot.
            time.sleep_ms(delay_ms);
            delay_ms = @min(delay_ms * 2, 80);

            continue;

        };

    }

}

/// Map and open the boot module bundle this program's assets ride in.
pub fn open_bundle() Error!bundle_mod.Bundle {

    const length: usize = @intCast(start.word(3));
    const offset: usize = @intCast(start.word(4));

    const base = try sys.map(cap.self_space, cap.gui.bundle, 0, sys.read);

    return bundle_mod.Bundle.open(base + offset, length) catch error.Invalid;

}

/// The proportional UI face (Inter) all apps draw with.
pub fn ui_font(bundle: *const bundle_mod.Bundle) Error!ttf.Face {

    const bytes = bundle.find("font-ttf") orelse return error.NotFound;

    return ttf.Face.parse(bytes) catch error.Invalid;

}

/// The fixed-width console face (JetBrains Mono) for the terminal cell grid and HTTP response bodies.
pub fn console_font(bundle: *const bundle_mod.Bundle) Error!ttf.Face {

    const bytes = bundle.find("font-mono") orelse return error.NotFound;

    return ttf.Face.parse(bytes) catch error.Invalid;

}
