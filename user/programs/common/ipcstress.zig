// Fine-grained IPC stress: clients call two endpoints concurrently, copy a handle in every request, and make each
// server signal that notification before replying. This drives independent endpoint queues and notification wakeups.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const page_size = 4096;
const stack_pages = 4;
const client_count = 8;
const server_count = 2;
const calls_per_client = 200;

var endpoints: [server_count]cap.Handle = undefined;
var signal: cap.Handle = 0;
var complete: cap.Handle = 0;
var next_server: usize = 0;
var next_client: usize = 0;
var completed: usize = 0;
var failed: usize = 0;

pub fn main(_: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    for (&endpoints) |*endpoint| endpoint.* = sys.create(.endpoint, 0, 0) catch return 1;

    signal = sys.create(.notification, 0, 0) catch return 1;
    complete = sys.create(.notification, 0, 0) catch return 1;

    for (0..server_count) |_| start_thread(&server_entry) catch return 1;
    for (0..client_count) |_| start_thread(&client_entry) catch return 1;

    while (@atomicLoad(usize, &completed, .acquire) < client_count) {

        _ = sys.wait(complete) catch return 1;

    }

    if (@atomicLoad(usize, &failed, .acquire) != 0) {

        lib.io.write(out, "ipcstress: FAIL\n") catch {};
        return 1;

    }

    lib.io.write(out, "ipcstress: 1600 calls ok\n") catch return 1;
    return 0;

}

fn start_thread(entry: *const fn () callconv(.c) noreturn) sys.Error!void {

    const stack = try sys.create(.region, stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(entry), base + stack_pages * page_size);

    try sys.start(thread);

}

fn server_entry() callconv(.c) noreturn {

    const index = @atomicRmw(usize, &next_server, .Add, 1, .acq_rel);
    const endpoint = endpoints[index % server_count];

    while (true) {

        var message = ipc.Message.zeroed;
        _ = sys.receive(endpoint, &message) catch continue;

        if (message.handle_count != 1) {

            _ = @atomicRmw(usize, &failed, .Add, 1, .acq_rel);

        } else {

            sys.notify(message.handles[0].handle, 1) catch {

                _ = @atomicRmw(usize, &failed, .Add, 1, .acq_rel);

            };

            sys.close(message.handles[0].handle) catch {};

        }

        const reply = message.reply;
        message = ipc.Message.zeroed;
        sys.reply(reply, &message) catch {};

    }

}

fn client_entry() callconv(.c) noreturn {

    const index = @atomicRmw(usize, &next_client, .Add, 1, .acq_rel);

    for (0..calls_per_client) |round| {

        var message = ipc.Message.zeroed;
        message.data[0] = index;
        message.data[1] = round;
        message.handles[0] = .{ .handle = signal, .move = false };
        message.handle_count = 1;

        sys.call(endpoints[(index + round) % server_count], &message) catch {

            _ = @atomicRmw(usize, &failed, .Add, 1, .acq_rel);
            break;

        };

    }

    _ = @atomicRmw(usize, &completed, .Add, 1, .acq_rel);
    sys.notify(complete, 1) catch {};

    lib.start.exit();

}
