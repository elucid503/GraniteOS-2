const std = @import("std");

const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");
const wav = @import("wav.zig");

const Handle = cap.Handle;

/// Fixed-point playback gain (no FP in userspace): 256 is unity, 0 is silence.
pub const gain_unity: u32 = 256;

pub const Client = struct {

    endpoint: Handle,
    buffer: Handle,
    base: usize,

    pub fn connect(authority: Handle) !Client {

        const endpoint = try stream.lookup_endpoint("audio");
        errdefer sys.close(endpoint) catch {};

        const buffer = try sys.create(.region, proto.audio.max_write, authority);
        errdefer sys.close(buffer) catch {};

        const base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);
        errdefer sys.unmap(cap.self_space, base) catch {};

        _ = try ipc.request(endpoint, proto.audio.attach, &.{proto.audio.max_write}, &.{

            .{ .handle = buffer, .move = false },

        });

        return .{ .endpoint = endpoint, .buffer = buffer, .base = base };

    }

    pub fn deinit(self: *Client) void {

        self.stop() catch {};
        sys.unmap(cap.self_space, self.base) catch {};
        sys.close(self.buffer) catch {};
        sys.close(self.endpoint) catch {};

    }

    pub fn configure(self: *Client, rate: u32, channels: u16) !void {

        _ = try ipc.request(self.endpoint, proto.audio.configure, &.{ rate, channels, proto.audio.format_s16_le }, &.{});

    }

    pub fn write(self: *Client, bytes: []const u8) !usize {

        const amount = @min(bytes.len, proto.audio.max_write);
        const buffer: [*]u8 = @ptrFromInt(self.base);

        @memcpy(buffer[0..amount], bytes[0..amount]);

        const reply = try ipc.request(self.endpoint, proto.audio.write, &.{ 0, amount }, &.{});

        return @intCast(reply.data[1]);

    }

    pub fn drain(self: *Client) !void {

        _ = try ipc.request(self.endpoint, proto.audio.drain, &.{}, &.{});

    }

    /// End a stream cleanly: push a short tail of silence so an underrun after the last real
    /// frame plays as silence rather than a repeated period, then wait for the device to catch up.
    pub fn flush(self: *Client) !void {

        const tail = 4096;
        const buffer: [*]u8 = @ptrFromInt(self.base);

        @memset(buffer[0..tail], 0);
        _ = ipc.request(self.endpoint, proto.audio.write, &.{ 0, tail }, &.{}) catch {};

        try self.drain();

    }

    pub fn stop(self: *Client) !void {

        _ = try ipc.request(self.endpoint, proto.audio.stop, &.{}, &.{});

    }

};

pub const Chunk = struct {

    bytes: []const u8,
    consumed: usize,

};

/// Convert up to one `max_write` chunk of `wave` at byte `offset` into signed 16-bit little-endian,
/// applying `gain` (256 = unity). 16-bit input at unity gain is returned as a zero-copy slice of the
/// source; every other case is materialized into `scratch`.
pub fn convert(wave_data: wav.Wave, offset: usize, scratch: []u8, gain: u32) Chunk {

    const block = wave_data.format.block_align;

    if (wave_data.format.bits_per_sample == 16) {

        const amount = @min(wave_data.samples.len - offset, scratch.len);
        const aligned = amount - amount % block;
        const source = wave_data.samples[offset .. offset + aligned];

        if (gain == gain_unity) return .{ .bytes = source, .consumed = aligned };

        var index: usize = 0;

        while (index + 1 < aligned) : (index += 2) {

            const sample: i16 = @bitCast(@as(u16, source[index]) | (@as(u16, source[index + 1]) << 8));
            const bits = apply_gain(sample, gain);

            scratch[index] = @truncate(bits);
            scratch[index + 1] = @truncate(bits >> 8);

        }

        return .{ .bytes = scratch[0..aligned], .consumed = aligned };

    }

    const amount = @min(wave_data.samples.len - offset, scratch.len / 2);
    const aligned = amount - amount % block;

    for (wave_data.samples[offset .. offset + aligned], 0..) |sample, index| {

        const signed: i16 = (@as(i16, sample) - 128) << 8;
        const bits = apply_gain(signed, gain);

        scratch[index * 2] = @truncate(bits);
        scratch[index * 2 + 1] = @truncate(bits >> 8);

    }

    return .{ .bytes = scratch[0 .. aligned * 2], .consumed = aligned };

}

fn apply_gain(sample: i16, gain: u32) u16 {

    if (gain == gain_unity) return @bitCast(sample);

    const scaled = @divTrunc(@as(i32, sample) * @as(i32, @intCast(gain)), gain_unity);

    return @bitCast(@as(i16, @intCast(std.math.clamp(scaled, -32768, 32767))));

}
