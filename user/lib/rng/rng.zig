// Freestanding CSPRNG: process-local ChaCha, seeded from virtio-rng (weak time mix as fallback).

const std = @import("std");
const builtin = @import("builtin");

const time = @import("../time.zig");
const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");
const sync = @import("../sync.zig");

const Csprng = std.Random.DefaultCsprng;
const seed_len = Csprng.secret_seed_length;

const State = enum { uninit, weak, strong };

var state: State = .uninit;
var csprng: Csprng = undefined;
var lock: sync.Mutex = .{};

/// Root-module std_options for freestanding crypto + page size.
pub const std_options: std.Options = .{

    .cryptoRandomSeed = fill,
    .crypto_always_getrandom = true,
    .page_size_min = 4096,
    .page_size_max = 4096,

};

/// `std.crypto.random` hook. With `crypto_always_getrandom` every `crypto.random.bytes` lands here.
pub fn fill(buffer: []u8) void {

    lock.acquire();
    defer lock.release();

    ensure_seeded_locked();
    csprng.fill(buffer);

}

pub fn is_strong() bool {

    lock.acquire();
    defer lock.release();

    return state == .strong;

}

/// Pull virtio-rng entropy and mix it in. Safe to call often; no-ops if the driver is unavailable.
pub fn try_reseed_from_driver() void {

    if (builtin.os.tag != .freestanding) return;

    var entropy: [64]u8 = undefined;
    const n = read_driver_entropy(&entropy) catch return;

    if (n == 0 or !entropy_usable(entropy[0..n])) return;

    lock.acquire();
    defer lock.release();

    reseed_locked(entropy[0..n]);

}

/// Block briefly until the CSPRNG is hardware-seeded. Call before TLS handshakes.
pub fn ensure_strong() bool {

    if (builtin.os.tag != .freestanding) return true;

    var attempt: u8 = 0;

    while (attempt < 8) : (attempt += 1) {

        if (is_strong()) return true;

        try_reseed_from_driver();

        if (is_strong()) return true;

        time.sleep_ms(15);

    }

    // Last resort so crypto can proceed; handshake may still fail rare IdentityElement cases.
    lock.acquire();
    ensure_seeded_locked();
    lock.release();

    return is_strong();

}

fn read_driver_entropy(out: []u8) !usize {

    const endpoint = stream.lookup_endpoint("rng") catch return error.NotFound;
    defer sys.close(endpoint) catch {};

    const buffer = try sys.create(.region, 4096, cap.memory);
    defer sys.close(buffer) catch {};

    const base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);
    defer sys.unmap(cap.self_space, base) catch {};

    // Clear so a driver race that writes into another client's buffer cannot leave stale "success".
    @memset(out[0..@min(out.len, 64)], 0);

    const dest: [*]u8 = @ptrFromInt(base);

    @memset(dest[0..4096], 0);

    _ = try ipc.request(endpoint, proto.entropy.attach, &.{4096}, &.{

        .{ .handle = buffer, .move = false },

    });
    defer _ = ipc.request(endpoint, proto.entropy.detach, &.{}, &.{}) catch {};

    const amount = @min(out.len, 4096);
    const reply = try ipc.request(endpoint, proto.entropy.read, &.{amount}, &.{});
    const length: usize = @intCast(reply.data[1]);

    if (length == 0 or length > out.len) return 0;

    @memcpy(out[0..length], dest[0..length]);

    return length;

}

fn reseed_locked(entropy: []const u8) void {

    var seed: [seed_len]u8 = undefined;

    if (state != .uninit) {

        csprng.fill(&seed);

    } else {

        @memset(&seed, 0);
        mix_weak(&seed);

    }

    var i: usize = 0;

    while (i < entropy.len) : (i += 1) {

        seed[i % seed_len] ^= entropy[i];

    }

    // Stir length and a counter so short or patterned entropy still moves the state.
    seed[0] ^= @truncate(entropy.len);
    seed[1] ^= @truncate(entropy.len >> 8);
    write_u64(&seed, seed_len - 8, time.now_ns());

    if (is_all_zero(&seed)) seed[0] = 1;

    csprng = Csprng.init(seed);
    std.crypto.secureZero(u8, &seed);
    state = .strong;

}

fn ensure_seeded_locked() void {

    if (state != .uninit) return;

    var seed: [seed_len]u8 = undefined;
    @memset(&seed, 0);

    mix_weak(&seed);

    if (is_all_zero(&seed)) seed[0] = 0xa5;

    csprng = Csprng.init(seed);
    std.crypto.secureZero(u8, &seed);
    state = .weak;

}

fn mix_weak(seed: *[seed_len]u8) void {

    const build_options = @import("build_options");
    const epoch = build_options.build_epoch_s;
    const ns = time.now_ns();
    const ms = time.now_ms();

    write_u64(seed, 0, @bitCast(epoch));
    write_u64(seed, 8, ns);
    write_u64(seed, 16, ms);
    write_u64(seed, 24, @intFromPtr(seed));

    var i: usize = 32;
    var counter: u64 = ns ^ @as(u64, @bitCast(epoch));

    while (i + 8 <= seed_len) : (i += 8) {

        counter = counter *% 0x9e3779b97f4a7c15 +% 1;
        write_u64(seed, i, counter);

    }

}

fn write_u64(seed: *[seed_len]u8, offset: usize, value: u64) void {

    if (offset + 8 > seed_len) return;

    std.mem.writeInt(u64, seed[offset..][0..8], value, .little);

}

fn is_all_zero(seed: *const [seed_len]u8) bool {

    for (seed.*) |b| if (b != 0) return false;

    return true;

}

/// Reject empty, all-zero, or trivially constant buffers (driver race / failed virtio fill).
fn entropy_usable(bytes: []const u8) bool {

    if (bytes.len < 16) return false;

    var seen_nonzero: u32 = 0;
    const first = bytes[0];
    var all_same = true;

    for (bytes) |b| {

        if (b != 0) seen_nonzero += 1;
        if (b != first) all_same = false;

    }

    if (all_same) return false;

    // At least a quarter of the bytes should be non-zero for a 64-byte virtio draw.
    return seen_nonzero >= bytes.len / 4;

}

/// Mix virtio-rng bytes into a fresh CSPRNG seed (public for tests).
pub fn reseed(entropy: []const u8) void {

    lock.acquire();
    defer lock.release();

    reseed_locked(entropy);

}

const testing = std.testing;

test "fill produces differing buffers" {

    lock.acquire();
    state = .uninit;
    lock.release();

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    fill(&a);
    fill(&b);

    try testing.expect(!std.mem.eql(u8, &a, &b));

}

test "reseed marks strong" {

    lock.acquire();
    state = .uninit;
    lock.release();

    var entropy: [32]u8 = undefined;

    for (&entropy, 0..) |*b, i| b.* = @truncate(i +% 3);

    reseed(&entropy);
    try testing.expect(is_strong());

    var out: [16]u8 = undefined;
    fill(&out);

    var any: bool = false;

    for (out) |b| if (b != 0) {

        any = true;
        break;

    };

    try testing.expect(any);

}

test "rejects unusable entropy" {

    try testing.expect(!entropy_usable(&[_]u8{0} ** 32));
    try testing.expect(!entropy_usable(&[_]u8{0xAA} ** 32));
    try testing.expect(!entropy_usable(&[_]u8{1, 2, 3}));

    var good: [32]u8 = undefined;

    for (&good, 0..) |*b, i| b.* = @truncate(i +% 1);

    try testing.expect(entropy_usable(&good));

}
