// Freestanding CSPRNG: process-local ChaCha, seeded once (weak mix or virtio-rng).

const std = @import("std");
const builtin = @import("builtin");

const time = @import("../time.zig");
const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

const Csprng = std.Random.DefaultCsprng;
const seed_len = Csprng.secret_seed_length;

var state: enum { uninit, weak, strong } = .uninit;
var csprng: Csprng = undefined;
var weak_logged: bool = false;

/// Root-module std_options for freestanding crypto + page size.
pub const std_options: std.Options = .{

    .cryptoRandomSeed = fill,
    .crypto_always_getrandom = true,
    .page_size_min = 4096,
    .page_size_max = 4096,

};

/// `std.crypto.random` hook: CSPRNG output only (never re-mixes entropy per call).
pub fn fill(buffer: []u8) void {

    ensure_seeded();
    csprng.fill(buffer);

}

pub fn is_strong() bool {

    return state == .strong;

}

/// Best-effort: pull entropy from the virtio-rng driver and reseed.
pub fn try_reseed_from_driver() void {

    if (builtin.os.tag != .freestanding) return;
    if (state == .strong) return;

    var entropy: [64]u8 = undefined;
    const n = read_driver_entropy(&entropy) catch return;

    if (n == 0) return;

    reseed(entropy[0..n]);

}

fn read_driver_entropy(out: []u8) !usize {

    const endpoint = stream.lookup_endpoint("rng") catch return error.NotFound;
    defer sys.close(endpoint) catch {};

    const buffer = try sys.create(.region, 4096, cap.memory);
    defer sys.close(buffer) catch {};

    const base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);
    defer sys.unmap(cap.self_space, base) catch {};

    _ = try ipc.request(endpoint, proto.entropy.attach, &.{4096}, &.{

        .{ .handle = buffer, .move = false },

    });

    const amount = @min(out.len, 4096);
    const reply = try ipc.request(endpoint, proto.entropy.read, &.{amount}, &.{});
    const length: usize = @intCast(reply.data[1]);

    if (length == 0) return 0;

    const source: [*]const u8 = @ptrFromInt(base);

    @memcpy(out[0..length], source[0..length]);

    return length;

}

/// Mix virtio-rng bytes into a fresh CSPRNG seed (strong path).
pub fn reseed(entropy: []const u8) void {

    var seed: [seed_len]u8 = undefined;

    if (state != .uninit) {

        csprng.fill(&seed);

    } else {

        @memset(&seed, 0);

    }

    var i: usize = 0;

    while (i < entropy.len) : (i += 1) {

        seed[i % seed_len] ^= entropy[i];

    }

    // Avoid all-zero seed (ClientHello InsufficientEntropy).
    if (is_all_zero(&seed)) seed[0] = 1;

    csprng = Csprng.init(seed);
    std.crypto.secureZero(u8, &seed);
    state = .strong;

}

fn ensure_seeded() void {

    if (state != .uninit) return;

    var seed: [seed_len]u8 = undefined;
    @memset(&seed, 0);

    mix_weak(&seed);

    if (is_all_zero(&seed)) seed[0] = 0xa5;

    csprng = Csprng.init(seed);
    std.crypto.secureZero(u8, &seed);
    state = .weak;

    if (!weak_logged and builtin.os.tag == .freestanding) {

        weak_logged = true;
        // Logging may not be ready; silent is fine. Callers can check is_strong().

    }

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

    // Stir with a cheap counter mix across the rest.
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

const testing = std.testing;

test "fill produces differing buffers" {

    state = .uninit;

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    fill(&a);
    fill(&b);

    try testing.expect(!std.mem.eql(u8, &a, &b));

}

test "reseed marks strong" {

    state = .uninit;

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
