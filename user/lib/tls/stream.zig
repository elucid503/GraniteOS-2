// Socket ↔ encrypted std.Io.Reader / Writer for vendored TLS Client.

const std = @import("std");

const net = @import("../net/net.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;

pub const Bridge = struct {

    socket: *net.Socket,
    reader: Reader,
    writer: Writer,

    pub fn init(socket: *net.Socket, read_buf: []u8, write_buf: []u8) Bridge {

        return .{

            .socket = socket,
            .reader = .{

                .vtable = &.{

                    .stream = stream,
                    .readVec = readVec,

                },
                .buffer = read_buf,
                .seek = 0,
                .end = 0,

            },
            .writer = .{

                .vtable = &.{

                    .drain = drain,

                },
                .buffer = write_buf,
                .end = 0,

            },

        };

    }

    fn stream(io_r: *Reader, io_w: *Writer, limit: Limit) Reader.StreamError!usize {

        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var bufs: [1][]u8 = .{dest};
        const n = try readVec(io_r, &bufs);

        io_w.advance(n);

        return n;

    }

    fn readVec(io_r: *Reader, data: [][]u8) Reader.Error!usize {

        const self: *Bridge = @alignCast(@fieldParentPtr("reader", io_r));

        if (data.len == 0) return 0;

        // Prefer the caller's first buffer; fall back to filling Reader.buffer.
        const dest: []u8 = if (data[0].len != 0) data[0] else blk: {

            const unused = io_r.buffer[io_r.end..];

            if (unused.len == 0) return 0;

            break :blk unused;

        };

        if (dest.len == 0) return 0;

        const n = self.socket.recv(dest) catch return error.ReadFailed;

        if (n == 0) return error.EndOfStream;

        if (data[0].len == 0) {

            io_r.end += n;

            return 0;

        }

        return n;

    }

    fn drain(io_w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {

        const self: *Bridge = @alignCast(@fieldParentPtr("writer", io_w));
        var sent: usize = 0;

        const buffered = io_w.buffered();

        if (buffered.len != 0) {

            self.socket.send_all(buffered) catch return error.WriteFailed;
            sent += buffered.len;

        }

        if (data.len != 0) {

            for (data[0 .. data.len - 1]) |slice| {

                self.socket.send_all(slice) catch return error.WriteFailed;
                sent += slice.len;

            }

            const pattern = data[data.len - 1];
            var i: usize = 0;

            while (i < splat) : (i += 1) {

                self.socket.send_all(pattern) catch return error.WriteFailed;
                sent += pattern.len;

            }

        }

        // consume: clears buffered prefix from `sent`, returns bytes taken from `data`.
        return io_w.consume(sent);

    }

};
