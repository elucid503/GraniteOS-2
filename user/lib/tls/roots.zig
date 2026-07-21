// Embedded CA bundle loaded via PEM + parseCert (no host FS / timestamp).

const std = @import("std");

const Certificate = std.crypto.Certificate;
const Bundle = Certificate.Bundle;

const pem_bytes = @embedFile("roots/cacert.pem");

const begin_marker = "-----BEGIN CERTIFICATE-----";
const end_marker = "-----END CERTIFICATE-----";

const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

var bundle: Bundle = .{};
var initialized: bool = false;

pub fn ensure_init(allocator: std.mem.Allocator, now_sec: i64) !void {

    if (initialized) return;

    try load(allocator, now_sec);
    initialized = true;

}

pub fn get() Bundle {

    std.debug.assert(initialized);

    return bundle;

}

fn load(gpa: std.mem.Allocator, now_sec: i64) !void {

    // Upper bound: decoded DER ≈ 3/4 of PEM; keep room for both.
    const needed = pem_bytes.len + pem_bytes.len / 4 * 3 + 4096;

    try bundle.bytes.ensureTotalCapacity(gpa, needed);

    var start_index: usize = 0;

    while (std.mem.indexOfPos(u8, pem_bytes, start_index, begin_marker)) |begin_marker_start| {

        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem_bytes, cert_start, end_marker) orelse return error.Invalid;

        start_index = cert_end + end_marker.len;

        const encoded = std.mem.trim(u8, pem_bytes[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);

        // Reserve decode space at the end of the array list buffer.
        const max_decoded = encoded.len / 4 * 3 + 4;

        try bundle.bytes.ensureUnusedCapacity(gpa, max_decoded);

        const dest = bundle.bytes.unusedCapacitySlice();
        const decoded_len = base64.decode(dest, encoded) catch continue;

        bundle.bytes.items.len += decoded_len;

        bundle.parseCert(gpa, decoded_start, now_sec) catch |err| switch (err) {

            error.CertificateHasUnrecognizedObjectId => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Drop this cert; keep loading others.
                bundle.bytes.items.len = decoded_start;
            },

        };

    }

    if (bundle.map.count() == 0) return error.Invalid;

}

const testing = std.testing;

test "loads embedded mozilla bundle" {

    const gpa = testing.allocator;
    var test_bundle: Bundle = .{};

    defer test_bundle.deinit(gpa);

    // Host tests use a fresh local bundle, not the process global.
    const needed = pem_bytes.len + pem_bytes.len / 4 * 3 + 4096;

    try test_bundle.bytes.ensureTotalCapacity(gpa, needed);

    var start_index: usize = 0;
    var loaded: usize = 0;
    const now_sec: i64 = 1_700_000_000; // ~2023; filters long-expired roots

    while (std.mem.indexOfPos(u8, pem_bytes, start_index, begin_marker)) |begin_marker_start| {

        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem_bytes, cert_start, end_marker) orelse break;

        start_index = cert_end + end_marker.len;

        const encoded = std.mem.trim(u8, pem_bytes[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(test_bundle.bytes.items.len);
        const max_decoded = encoded.len / 4 * 3 + 4;

        try test_bundle.bytes.ensureUnusedCapacity(gpa, max_decoded);

        const dest = test_bundle.bytes.unusedCapacitySlice();
        const decoded_len = base64.decode(dest, encoded) catch continue;

        test_bundle.bytes.items.len += decoded_len;
        test_bundle.parseCert(gpa, decoded_start, now_sec) catch {
            test_bundle.bytes.items.len = decoded_start;
            continue;
        };

        loaded += 1;

    }

    try testing.expect(loaded > 50);

}
