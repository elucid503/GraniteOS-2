// Global text selection: every string drawn through a Face is captured as a run, so any text on
// screen can be dragged over and copied, not only the contents of editable fields.

const std = @import("std");

const draw = @import("draw.zig");
const text_mod = @import("text.zig");

const Color = draw.Color;
const Face = text_mod.Face;
const Rect = draw.Rect;
const Surface = draw.Surface;

pub const max_runs = 128;

// Wide enough for a terminal line at the sizes the console grid reaches; longer strings still
// select, just not past this many bytes.
pub const max_run_bytes = 128;

/// Pointer travel before a press on text becomes a selection instead of a click.
pub const drag_threshold: i32 = 3;

/// Turned off wholesale by processes with no selectable chrome (the compositor draws titles).
pub var enabled = true;

pub var highlight: Color = draw.rgb(100, 100, 100);

const Run = struct {

    owner: usize = 0,
    face: ?*const Face = null,

    rect: Rect = Rect.empty,
    size: u32 = 0,
    mono: bool = false,

    len: u8 = 0,
    bytes: [max_run_bytes]u8 = [_]u8{0} ** max_run_bytes,

    fn slice(self: *const Run) []const u8 {

        return self.bytes[0..self.len];

    }

};

var runs: [max_runs]Run = [_]Run{.{}} ** max_runs;
var run_count: usize = 0;

// One owner's runs are dropped lazily: the surface that just presented a whole frame clears on its
// next draw, so a repaint replaces its runs without disturbing another window's.
var pending_clear: usize = 0;

var capturing = true;

var press_owner: usize = 0;
var press_x: i32 = 0;
var press_y: i32 = 0;
var pressed = false;

var sel_owner: usize = 0;
var sel_active = false;

var anchor_x: i32 = 0;
var anchor_y: i32 = 0;
var focus_x: i32 = 0;
var focus_y: i32 = 0;

/// Where the focused app last drew its caret, in window-local pixels (published to the compositor).
pub var caret: Rect = Rect.empty;

/// Stop capturing runs while a widget paints text it selects on its own terms (fields, editors).
pub fn pause_capture() void {

    capturing = false;

}

pub fn resume_capture() void {

    capturing = true;

}

/// Record `text` and paint the selection highlight under it; the single hook Face.draw calls.
pub fn observe(surface: *const Surface, face: *const Face, rect: Rect, size: u32, mono: bool, bytes: []const u8) void {

    if (!enabled or bytes.len == 0 or rect.w <= 0 or rect.h <= 0) return;

    const owner = @intFromPtr(surface.pixels);

    if (capturing) record(owner, face, rect, size, mono, bytes);

    const span = span_of(owner, face, rect, size, mono, bytes) orelse return;

    surface.fill_rect(span, highlight);

}

fn record(owner: usize, face: *const Face, rect: Rect, size: u32, mono: bool, bytes: []const u8) void {

    if (pending_clear == owner) {

        drop_owner(owner);
        pending_clear = 0;

    }

    const slot = slot_for(owner, rect, size) orelse return;
    const length = @min(bytes.len, max_run_bytes);

    slot.* = .{

        .owner = owner,
        .face = face,

        .rect = rect,
        .size = size,
        .mono = mono,

        .len = @intCast(length),

    };

    @memcpy(slot.bytes[0..length], bytes[0..length]);

}

// A repaint redraws the same string at the same origin, so matching origins replace in place.

fn slot_for(owner: usize, rect: Rect, size: u32) ?*Run {

    for (runs[0..run_count]) |*run| {

        if (run.owner == owner and run.rect.x == rect.x and run.rect.y == rect.y and run.size == size) return run;

    }

    // Full because a view replaced its layout without ever presenting whole frames: start this
    // surface over rather than wedging the table with runs that are no longer on screen.
    if (run_count >= max_runs) {

        drop_owner(owner);

        if (run_count >= max_runs) return null;

    }

    const slot = &runs[run_count];
    run_count += 1;

    return slot;

}

fn drop_owner(owner: usize) void {

    var written: usize = 0;

    for (runs[0..run_count]) |run| {

        if (run.owner == owner) continue;

        runs[written] = run;
        written += 1;

    }

    run_count = written;

}

/// A surface finished a full-surface present: its runs are stale from the next draw onward.
pub fn end_frame(owner: usize) void {

    pending_clear = owner;

}

pub fn forget(owner: usize) void {

    drop_owner(owner);

    if (pending_clear == owner) pending_clear = 0;
    if (sel_owner == owner) _ = clear();

}

// Geometry: prefix widths drive both hit-testing and the highlight span.

/// Width of `bytes` under either metric; monospace steps by whole cells, one per codepoint.
pub fn prefix_width(face: *const Face, size: u32, mono: bool, bytes: []const u8) i32 {

    if (!mono) return face.text_width(bytes, size);

    return face.mono_width(size) * @as(i32, @intCast(codepoints(bytes)));

}

fn codepoints(bytes: []const u8) usize {

    var count: usize = 0;

    for (bytes) |byte| {

        if (byte & 0xc0 != 0x80) count += 1;

    }

    return count;

}

/// Byte index in `bytes` nearest to `x` pixels from the run's left edge.
fn index_at(face: *const Face, size: u32, mono: bool, bytes: []const u8, x: i32) usize {

    if (x <= 0) return 0;

    var index: usize = 0;
    var previous: i32 = 0;

    while (index < bytes.len) {

        var next = index + 1;

        while (next < bytes.len and bytes[next] & 0xc0 == 0x80) next += 1;

        const width = prefix_width(face, size, mono, bytes[0..next]);

        if (width > x) {

            const middle = previous + @divTrunc(width - previous, 2);

            return if (x < middle) index else next;

        }

        previous = width;
        index = next;

    }

    return bytes.len;

}

// Reading order: -1 when the run sits above `y`, 1 when below, 0 when `y` falls inside its line box.

fn line_side(rect: Rect, y: i32) i32 {

    if (y < rect.y) return 1;
    if (y >= rect.y + rect.h) return -1;

    return 0;

}

const Range = struct {

    from: usize,
    to: usize,

};

fn selected_range(rect: Rect, face: *const Face, size: u32, mono: bool, bytes: []const u8) ?Range {

    if (!sel_active) return null;

    const start_first = anchor_y < focus_y or (anchor_y == focus_y and anchor_x <= focus_x);

    const start_x = if (start_first) anchor_x else focus_x;
    const start_y = if (start_first) anchor_y else focus_y;
    const end_x = if (start_first) focus_x else anchor_x;
    const end_y = if (start_first) focus_y else anchor_y;

    const at_start = line_side(rect, start_y);
    const at_end = line_side(rect, end_y);

    if (at_start == -1 or at_end == 1) return null;

    const from = if (at_start == 0) index_at(face, size, mono, bytes, start_x - rect.x) else 0;
    const to = if (at_end == 0) index_at(face, size, mono, bytes, end_x - rect.x) else bytes.len;

    if (to <= from) return null;

    return .{ .from = from, .to = to };

}

fn span_of(owner: usize, face: *const Face, rect: Rect, size: u32, mono: bool, bytes: []const u8) ?Rect {

    if (!sel_active or owner != sel_owner) return null;

    const range = selected_range(rect, face, size, mono, bytes) orelse return null;

    const left = rect.x + prefix_width(face, size, mono, bytes[0..range.from]);
    const right = rect.x + prefix_width(face, size, mono, bytes[0..range.to]);

    return .{ .x = left, .y = rect.y, .w = @max(1, right - left), .h = rect.h };

}

fn hit_run(owner: usize, x: i32, y: i32) bool {

    for (runs[0..run_count]) |*run| {

        if (run.owner != owner) continue;
        if (run.rect.contains(x, y)) return true;

    }

    return false;

}

// Pointer interaction. A press only arms the drag: plain clicks still reach buttons underneath.

pub fn press(owner: usize, x: i32, y: i32) bool {

    const cleared = clear();

    if (!enabled) return cleared;

    pressed = hit_run(owner, x, y);
    press_owner = owner;
    press_x = x;
    press_y = y;

    return cleared;

}

pub fn drag(owner: usize, x: i32, y: i32) bool {

    if (!pressed or owner != press_owner) return false;

    if (!sel_active) {

        const travel = @abs(x - press_x) + @abs(y - press_y);

        if (travel < drag_threshold) return false;

        sel_active = true;
        sel_owner = owner;
        anchor_x = press_x;
        anchor_y = press_y;

    }

    if (focus_x == x and focus_y == y) return false;

    focus_x = x;
    focus_y = y;

    return true;

}

pub fn release() void {

    pressed = false;

}

pub fn has_selection() bool {

    return sel_active;

}

/// Drop the selection; true when something was showing (repaint).
pub fn clear() bool {

    pressed = false;

    if (!sel_active) return false;

    sel_active = false;

    return true;

}

/// The selected text in reading order, lines joined by newlines and same-line runs by spaces.
pub fn selection(out: []u8) []const u8 {

    if (!sel_active or out.len == 0) return out[0..0];

    var order: [max_runs]usize = undefined;
    var count: usize = 0;

    for (runs[0..run_count], 0..) |*run, index| {

        if (run.owner != sel_owner or run.len == 0) continue;

        const face = run.face orelse continue;

        if (selected_range(run.rect, face, run.size, run.mono, run.slice()) == null) continue;

        order[count] = index;
        count += 1;

    }

    sort_reading_order(order[0..count]);

    var length: usize = 0;
    var previous_y: i32 = 0;

    for (order[0..count], 0..) |index, position| {

        const run = &runs[index];
        const face = run.face orelse continue;
        const range = selected_range(run.rect, face, run.size, run.mono, run.slice()) orelse continue;

        if (position > 0) {

            const separator: u8 = if (run.rect.y != previous_y) '\n' else ' ';

            if (length < out.len) {

                out[length] = separator;
                length += 1;

            }

        }

        const piece = run.bytes[range.from..range.to];
        const room = @min(piece.len, out.len - length);

        @memcpy(out[length..][0..room], piece[0..room]);
        length += room;
        previous_y = run.rect.y;

        if (length >= out.len) break;

    }

    return out[0..length];

}

fn sort_reading_order(order: []usize) void {

    var index: usize = 1;

    while (index < order.len) : (index += 1) {

        const value = order[index];
        var position = index;

        while (position > 0 and before(value, order[position - 1])) : (position -= 1) {

            order[position] = order[position - 1];

        }

        order[position] = value;

    }

}

fn before(left: usize, right: usize) bool {

    const a = runs[left].rect;
    const b = runs[right].rect;

    if (a.y != b.y) return a.y < b.y;

    return a.x < b.x;

}

const testing = std.testing;

test "line_side orders a run against a point" {

    const rect = Rect{ .x = 10, .y = 20, .w = 100, .h = 16 };

    try testing.expectEqual(@as(i32, 1), line_side(rect, 4));
    try testing.expectEqual(@as(i32, 0), line_side(rect, 20));
    try testing.expectEqual(@as(i32, 0), line_side(rect, 35));
    try testing.expectEqual(@as(i32, -1), line_side(rect, 36));

}

test "codepoints counts utf8 characters, not bytes" {

    try testing.expectEqual(@as(usize, 3), codepoints("abc"));
    try testing.expectEqual(@as(usize, 2), codepoints("a\u{00e9}"));

}

test "a press without travel never becomes a selection" {

    defer _ = clear();

    run_count = 0;
    runs[0] = .{ .owner = 7, .rect = .{ .x = 0, .y = 0, .w = 40, .h = 16 }, .len = 3 };
    run_count = 1;

    _ = press(7, 5, 5);

    try testing.expect(!drag(7, 6, 5));
    try testing.expect(!has_selection());

    try testing.expect(drag(7, 30, 5));
    try testing.expect(has_selection());

    release();

    try testing.expect(clear());
    try testing.expect(!has_selection());

}
