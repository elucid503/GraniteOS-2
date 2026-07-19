// System cursor kinds uploaded to the compositor hardware cursor plane.

const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");

const gfx = @import("../draw/draw.zig");
const icons = @import("icons.zig");
const svg = @import("../draw/vector.zig");

const window = @import("window.zig");

pub const Kind = enum(u8) {

    pointer = 0,
    clicker = 1,
    selector = 2,

};

const fill_color: gfx.Color = 0xffff_ffff;
const outline_color: gfx.Color = 0xff00_0000;

const icon_size: i32 = 20;

pub fn hot_spot(kind: Kind) struct { x: u32, y: u32 } {

    return switch (kind) {

        .pointer => .{ .x = 0, .y = 0 },
        .clicker => .{ .x = 6, .y = 3 },
        .selector => .{ .x = 12, .y = 4 },

    };

}

/// Paint a 64x64 ARGB cursor into `pixels` (length must be side * side).
pub fn paint(side: usize, kind: Kind, pixels: [*]u32) void {

    const source = switch (kind) {

        .pointer => icons.pointer,
        .clicker => icons.hand,
        .selector => icons.text_cursor,

    };

    const style = switch (kind) {

        .pointer => svg.CursorStyle.filled,
        .clicker => svg.CursorStyle.stroked,
        .selector => svg.CursorStyle.white_line,

    };

    svg.raster_cursor(side, pixels, source, icon_rect(kind), fill_color, outline_color, style);

}

// Skip the IPC when the kind is unchanged; pointer moves fire this on every pixel.
var cached_endpoint: cap.Handle = 0;
var cached_kind: ?Kind = null;

/// Tell the compositor which cursor belongs over this client's surface.
pub fn set(connection: *const window.Connection, kind: Kind) void {

    if (cached_endpoint == connection.endpoint) {

        if (cached_kind) |previous| {

            if (previous == kind) return;

        }

    }

    cached_endpoint = connection.endpoint;
    cached_kind = kind;

    _ = ipc.request(connection.endpoint, proto.window.set_cursor, &.{@intFromEnum(kind)}, &.{}) catch {};

}

fn icon_rect(kind: Kind) gfx.Rect {

    return switch (kind) {

        // Lucide mouse-pointer-2 tip sits at (4, 4) in a 24x24 view box.
        .pointer => .{ .x = -4, .y = -4, .w = icon_size, .h = icon_size },
        .clicker => .{ .x = 1, .y = 0, .w = icon_size, .h = icon_size },
        .selector => .{ .x = 0, .y = 0, .w = icon_size, .h = icon_size },

    };

}
