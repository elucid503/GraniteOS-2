// The launcher: the desktop's program spawner.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

const home_dir = "/root/user";

const worker_stack_pages = 16;
const page_size = 4096;

var bundle: lib.bundle.Bundle = undefined;
var bundle_length: usize = 0;
var bundle_offset: usize = 0;
var core_count: u64 = 1;

// GUI children report their exit here; a worker drains the deaths so an exiting child's one-way send never stalls.
var deaths: Handle = 0;
var next_child: u64 = 1;

var lock: ipc.Lock = .{};

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    bundle_length = @intCast(lib.start.word(3));
    bundle_offset = @intCast(lib.start.word(4));
    core_count = @max(1, lib.start.word(proto.init.core_count_word));

    const base = try sys.map(cap.self_space, cap.launcher.bundle, 0, sys.read);
    bundle = try lib.bundle.Bundle.open(base + bundle_offset, bundle_length);

    deaths = try sys.create(.endpoint, 0, 0);

    try start_reaper();

    ipc.serve(cap.launcher.endpoint, dispatch);

}

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    _ = badge;

    return switch (method) {

        proto.identify => identify(out),
        proto.launch.spawn => spawn(in),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.launch.interface_id;
    out.data[2] = proto.launch.version;

    return 0;

}

fn spawn(in: *const Message) i64 {

    var name_bytes: [proto.launch.max_length]u8 = undefined;
    const name = decode_name(in, &name_bytes) orelse return -7;

    const image = bundle.find(name) orelse return -6;

    lock.acquire();
    defer lock.release();

    spawn_gui(name, image) catch return -3;

    return 0;

}

fn spawn_gui(name: []const u8, image: []const u8) !void {

    const init_endpoint = try sys.create(.endpoint, 0, 0);
    errdefer sys.close(init_endpoint) catch {};

    const report = try sys.copy(deaths, next_child);
    errdefer sys.close(report) catch {};

    next_child += 1;

    const grants = [_]Handle{

        cap.launcher.console,
        cap.launcher.console,
        cap.launcher.console,
        cap.name_service,
        cap.memory,
        init_endpoint,
        report,
        cap.launcher.bundle,

    };

    const child = try lib.elf.spawn_program(.{

        .image = image,
        .authority = cap.memory,
        .args = &.{name},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,
        .data5 = core_count,
        .cwd = home_dir,

    });

    sys.close(child) catch {};
    sys.close(init_endpoint) catch {};
    sys.close(report) catch {};

}

// The name rides inline exactly like the name service's: word 1 is the length, words 2-5 the NUL-padded bytes.

fn decode_name(in: *const Message, out: *[proto.launch.max_length]u8) ?[]const u8 {

    const length: usize = @intCast(in.data[1]);

    if (length == 0 or length > out.len) return null;

    for (0..4) |index| {

        std.mem.writeInt(u64, out[index * 8 ..][0..8], in.data[2 + index], .little);

    }

    return out[0..length];

}

fn start_reaper() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&reaper), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn reaper() callconv(.c) noreturn {

    var message = Message.zeroed;

    while (true) {

        _ = sys.receive(deaths, &message) catch {};

    }

}
