// TLS client Session over lib.net.Socket. Immovable after handshake.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const mem = @import("../mem/mem.zig");
const net = @import("../net/net.zig");
const sys = @import("../syscall/sys.zig");
const time = @import("../time.zig");
const rng = @import("../rng/rng.zig");

const Client = @import("client.zig");
const stream_mod = @import("stream.zig");
const roots = @import("roots.zig");

const Handle = cap.Handle;

pub const Error = error{

    ReadFailed,
    WriteFailed,
    OutOfMemory,
    Gone,
    Invalid,
    InsufficientEntropy,
    TlsAlert,
    TlsUnexpectedMessage,
    TlsIllegalParameter,
    TlsDecryptFailure,
    TlsRecordOverflow,
    TlsBadRecordMac,
    TlsConnectionTruncated,
    TlsDecodeError,
    TlsCertificateNotVerified,
    CertificateHostMismatch,
    CertificateExpired,
    CertificateNotYetValid,
    CertificateIssuerMismatch,
    CertificatePublicKeyInvalid,
    CertificateSignatureInvalid,
    CertificateTimeInvalid,
    TlsHandshakeFailed,

} || sys.Error;

/// After connect_host succeeds: immovable until close. Do not return by value or memcpy.
pub const Session = struct {

    socket: net.Socket,
    client: Client,
    bridge: stream_mod.Bridge,

    enc_in_buf: []u8,
    enc_out_buf: []u8,
    plain_in_buf: []u8,
    plain_out_buf: []u8,

    heap: *mem.Heap,
    authority: Handle,

    /// TCP + TLS handshake into `out` (stable address). Allocates four large buffers via Heap.
    pub fn connect_host(out: *Session, authority: Handle, heap: *mem.Heap, host: []const u8, port: u16) Error!void {

        pull_rng_and_time();
        try roots.ensure_init(heap.allocator(), time.wall_sec());

        var socket = try net.Socket.connect_host(authority, host, port);

        errdefer socket.close();

        try finish_handshake(out, authority, heap, socket, host);

    }

    pub fn send_all(self: *Session, bytes: []const u8) Error!void {

        // Client.writer encrypts into client.output (bridge.writer)

        self.client.writer.writeAll(bytes) catch return error.WriteFailed;
        self.client.writer.flush() catch return error.WriteFailed;
        self.client.output.flush() catch return error.WriteFailed;

    }

    pub fn recv(self: *Session, out: []u8) Error!usize {

        // readSliceShort returns 0 at EOF (ShortError is only ReadFailed).

        return self.client.reader.readSliceShort(out) catch return error.ReadFailed;

    }

    pub fn close(self: *Session) void {

        // end() stages close_notify into output; flush so it actually sends.

        self.client.end() catch {};
        self.client.output.flush() catch {};
        self.socket.close();

        if (self.enc_in_buf.len != 0) self.heap.free(self.enc_in_buf);
        if (self.enc_out_buf.len != 0) self.heap.free(self.enc_out_buf);
        if (self.plain_in_buf.len != 0) self.heap.free(self.plain_in_buf);
        if (self.plain_out_buf.len != 0) self.heap.free(self.plain_out_buf);

        self.enc_in_buf = &.{};
        self.enc_out_buf = &.{};
        self.plain_in_buf = &.{};
        self.plain_out_buf = &.{};

    }

};

fn finish_handshake(out: *Session, authority: Handle, heap: *mem.Heap, socket: net.Socket, host: []const u8,) Error!void {

    const n = Client.min_buffer_len;

    const enc_in = heap.alloc(n) catch return error.OutOfMemory;
    errdefer heap.free(enc_in);

    const enc_out = heap.alloc(n) catch return error.OutOfMemory;
    errdefer heap.free(enc_out);

    const plain_in = heap.alloc(n) catch return error.OutOfMemory;
    errdefer heap.free(plain_in);

    const plain_out = heap.alloc(n) catch return error.OutOfMemory;
    errdefer heap.free(plain_out);

    out.* = .{

        .socket = socket,
        .client = undefined,
        .bridge = undefined,

        .enc_in_buf = enc_in,
        .enc_out_buf = enc_out,
        .plain_in_buf = plain_in,
        .plain_out_buf = plain_out,

        .heap = heap,
        .authority = authority,

    };

    out.bridge = stream_mod.Bridge.init(&out.socket, enc_in, enc_out);

    out.client = Client.init(&out.bridge.reader, &out.bridge.writer, .{

        .host = .{ .explicit = host },
        .ca = .{ .bundle = roots.get() },
        .now_sec = time.wall_sec(),
        .read_buffer = plain_in,
        .write_buffer = plain_out,
        .allow_truncation_attacks = true,

    }) catch |err| return map_init_error(err);

}

fn map_init_error(err: anyerror) Error {

    return switch (err) {

        error.WriteFailed => error.WriteFailed,
        error.ReadFailed => error.ReadFailed,
        error.InsufficientEntropy => error.InsufficientEntropy,
        error.TlsAlert => error.TlsAlert,
        error.TlsUnexpectedMessage => error.TlsUnexpectedMessage,
        error.TlsIllegalParameter => error.TlsIllegalParameter,
        error.TlsDecryptFailure => error.TlsDecryptFailure,
        error.TlsRecordOverflow => error.TlsRecordOverflow,
        error.TlsBadRecordMac => error.TlsBadRecordMac,
        error.TlsConnectionTruncated => error.TlsConnectionTruncated,
        error.TlsDecodeError => error.TlsDecodeError,
        error.TlsCertificateNotVerified => error.TlsCertificateNotVerified,
        error.CertificateHostMismatch => error.CertificateHostMismatch,
        error.CertificateExpired => error.CertificateExpired,
        error.CertificateNotYetValid => error.CertificateNotYetValid,
        error.CertificateIssuerMismatch => error.CertificateIssuerMismatch,
        error.CertificatePublicKeyInvalid => error.CertificatePublicKeyInvalid,
        error.CertificateSignatureInvalid => error.CertificateSignatureInvalid,
        error.CertificateTimeInvalid => error.CertificateTimeInvalid,
        error.OutOfMemory => error.OutOfMemory,
        else => error.TlsHandshakeFailed,

    };

}

fn pull_rng_and_time() void {

    // Best-effort: reseed from virtio-rng and pull NTP offset from netstack.

    rng.try_reseed_from_driver();
    time.try_pull_wall_offset();

}
