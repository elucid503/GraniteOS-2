// Filesystem server (07-userspace-ddd.md Section 7): serves the Filesystem interface over a Strata volume backed by the block driver.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const format = @import("format.zig");

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

const workers = 3;
const block_size = format.block_size;
const sectors_per_block = block_size / proto.block.sector_size;

const max_path = 512;
const max_sessions = 16;
const max_open_files = 16;

// The block driver reached through the granted, badged endpoint; one shared one-block session buffer, plus a direct-mapped write-through block cache (07-userspace-ddd.md Section 7.2).

const cache_slots = 64;

const CacheEntry = struct {

    index: u32 = 0,
    valid: bool = false,

    data: [block_size]u8 = undefined,

};

const CachedDisk = struct {

    session_base: usize = 0,
    blocks: u64 = 0,

    cache: [cache_slots]CacheEntry = [_]CacheEntry{.{}} ** cache_slots,

    pub const Error = error{Io};

    fn connect(self: *CachedDisk) !void {

        const buffer = try sys.create(.region, block_size, cap.memory);
        self.session_base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);

        _ = try ipc.request(cap.filesystem.block, proto.block.attach, &.{block_size}, &.{

            .{ .handle = buffer, .move = false },

        });

        sys.close(buffer) catch {};

        const reply = try ipc.request(cap.filesystem.block, proto.block.capacity, &.{}, &.{});

        self.blocks = reply.data[1] / sectors_per_block;

        if (self.blocks == 0) return error.Invalid;

    }

    pub fn read_block(self: *CachedDisk, index: u32, out: *[block_size]u8) Error!void {

        const slot = &self.cache[index % cache_slots];

        if (slot.valid and slot.index == index) {

            out.* = slot.data;
            return;

        }

        var sector: u64 = 0;

        while (sector < sectors_per_block) : (sector += 1) {

            self.sector_call(proto.block.read_sector, @as(u64, index) * sectors_per_block + sector, sector * proto.block.sector_size);

        }

        const bytes: [*]const u8 = @ptrFromInt(self.session_base);

        @memcpy(out, bytes[0..block_size]);

        slot.* = .{

            .index = index,
            .valid = true,
            .data = out.*,

        };

    }

    pub fn write_block(self: *CachedDisk, index: u32, data: *const [block_size]u8) Error!void {

        const bytes: [*]u8 = @ptrFromInt(self.session_base);

        @memcpy(bytes[0..block_size], data);

        var sector: u64 = 0;

        while (sector < sectors_per_block) : (sector += 1) {

            self.sector_call(proto.block.write_sector, @as(u64, index) * sectors_per_block + sector, sector * proto.block.sector_size);

        }

        self.cache[index % cache_slots] = .{

            .index = index,
            .valid = true,
            .data = data.*,

        };

    }

    pub fn block_count(self: *CachedDisk) u64 {

        return self.blocks;

    }

    // A vanished block driver breaks every request (`Gone`); exit so the supervisor restarts this server too.

    fn sector_call(self: *CachedDisk, method: u16, sector: u64, offset: u64) void {

        _ = self;

        _ = ipc.request(cap.filesystem.block, method, &.{ sector, offset }, &.{}) catch {

            lib.start.exit_with(1);

        };

    }

};

const Volume = format.Volume(CachedDisk);

// Per-client state, keyed by badge (05-server-protocol.md): the attached session buffer and the open-file table.

const OpenFile = struct {

    inode: u32 = 0,
    used: bool = false,

};

const Files = struct {

    table: [max_open_files]OpenFile = [_]OpenFile{.{}} ** max_open_files,

};

const Sessions = lib.session.Sessions(Files, max_sessions);
const Session = Sessions.Session;

var disk: CachedDisk = .{};
var volume: Volume = undefined;
var sessions: Sessions = .{};

// One coarse lock over the volume, cache, and session tables; requests serialize inside the pool but every worker
// still shields its own caller from a crash mid-request.

var lock: ipc.Lock = .{};

pub fn main(_: []const []const u8) u8 {

    // Flint reports whether it found a virtio-blk transport in init word 3 (decision #19: boot survives no disk).

    if (lib.start.word(3) == 0) {

        log("Filesystem: no disk present; filesystem unavailable\n", .{});

        return 0;

    }

    disk.connect() catch {

        log("Filesystem: block driver unreachable; filesystem unavailable\n", .{});

        return 0;

    };

    // Mount the existing format; a blank disk is formatted on first boot (07-userspace-ddd.md Section 7.2).

    if (Volume.open(&disk)) |mounted| {

        volume = mounted;

        log("Filesystem: Strata volume mounted ({d} blocks)\n", .{volume.super.block_count});

    } else |failure| {

        if (failure != error.Invalid) return 1;

        volume = Volume.format(&disk) catch return 1;

        log("Filesystem: formatted fresh Strata volume ({d} blocks)\n", .{volume.super.block_count});

    }

    ipc.serve_pool(cap.server.endpoint, workers, dispatch);

}

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    lock.acquire();
    defer lock.release();

    return switch (method) {

        proto.identify => identify(out),
        proto.filesystem.open => open(badge, in),
        proto.filesystem.close => close(badge, in.data[1]),
        proto.filesystem.read => read(badge, in),
        proto.filesystem.write => write(badge, in),
        proto.filesystem.create => create(badge, in),
        proto.filesystem.delete => delete(badge, in),
        proto.filesystem.rename => rename(badge, in),
        proto.filesystem.list => list(badge, in),
        proto.filesystem.stat => stat(badge, in),
        proto.filesystem.mkdir => mkdir(badge, in),
        proto.filesystem.set_permissions => set_permissions(badge, in),
        proto.filesystem.attach => attach(badge, in),
        proto.filesystem.detach => detach(badge),
        proto.filesystem.info => info(badge, in),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.filesystem.interface_id;
    out.data[2] = proto.filesystem.version;

    return 0;

}

fn detach(badge: u64) i64 {

    sessions.close(badge);
    return 0;

}

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    const session = sessions.open(badge);

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session.capacity = @intCast(in.data[1]);

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn open(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;

    var path_buffer: [max_path]u8 = undefined;
    const path = copy_path(session, in.data[1], in.data[2], &path_buffer) orelse return -7;

    const flags = in.data[3];

    const inode = volume.resolve(path) catch |failure| missing: {

        if (failure != error.NotFound or flags & proto.filesystem.open_create == 0) return status_of(failure);

        break :missing volume.create(path, .file) catch |creation| return status_of(creation);

    };

    if ((volume.kind_of(inode) catch return -7) != .file) return -7;

    if (flags & proto.filesystem.open_truncate != 0) {

        volume.truncate(inode) catch |failure| return status_of(failure);

    }

    for (&session.extra.table, 0..) |*file, id| {

        if (file.used) continue;

        file.* = .{

            .inode = inode,
            .used = true,

        };

        return @intCast(id);

    }

    return -3; // NoMemory: the open-file table is full

}

fn close(badge: u64, id: u64) i64 {

    const file = file_for(badge, id) orelse return -1;

    file.used = false;

    return 0;

}

fn read(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;
    const file = file_for(badge, in.data[1]) orelse return -1;
    const span = session_span(session, in.data[3], in.data[4]) orelse return -7;

    const length = volume.read(file.inode, in.data[2], span) catch |failure| return status_of(failure);

    return @intCast(length);

}

fn write(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;
    const file = file_for(badge, in.data[1]) orelse return -1;
    const span = session_span(session, in.data[3], in.data[4]) orelse return -7;

    const length = volume.write(file.inode, in.data[2], span) catch |failure| return status_of(failure);

    return @intCast(length);

}

fn create(badge: u64, in: *const Message) i64 {

    const kind: format.Kind = switch (in.data[3]) {

        proto.filesystem.kind_file => .file,
        proto.filesystem.kind_directory => .directory,

        else => return -7,

    };

    return path_call(badge, in, kind, do_create);

}

fn mkdir(badge: u64, in: *const Message) i64 {

    return path_call(badge, in, .directory, do_create);

}

fn delete(badge: u64, in: *const Message) i64 {

    return path_call(badge, in, .none, do_delete);

}

fn rename(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;

    var old_buffer: [max_path]u8 = undefined;
    var new_buffer: [max_path]u8 = undefined;

    const old = copy_path(session, in.data[1], in.data[2], &old_buffer) orelse return -7;
    const new = copy_path(session, in.data[3], in.data[4], &new_buffer) orelse return -7;

    volume.rename(old, new) catch |failure| return status_of(failure);

    return 0;

}

fn list(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;

    var path_buffer: [max_path]u8 = undefined;
    const path = copy_path(session, in.data[1], in.data[2], &path_buffer) orelse return -7;
    const span = session_span(session, in.data[3], in.data[4]) orelse return -7;

    var entries: [64]format.ListEntry = undefined;
    const room = @min(entries.len, span.len / @sizeOf(proto.filesystem.Entry));

    const found = volume.list(path, entries[0..room]) catch |failure| return status_of(failure);

    for (entries[0..found], 0..) |entry, index| {

        var record = std.mem.zeroes(proto.filesystem.Entry);

        record.inode = entry.inode;
        record.kind = @intFromEnum(entry.kind);
        record.name_len = entry.name_len;
        record.length = entry.length;
        record.name = entry.name;

        @memcpy(span[index * @sizeOf(proto.filesystem.Entry) ..][0..@sizeOf(proto.filesystem.Entry)], std.mem.asBytes(&record));

    }

    return @intCast(found * @sizeOf(proto.filesystem.Entry));

}

fn stat(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;

    var path_buffer: [max_path]u8 = undefined;
    const path = copy_path(session, in.data[1], in.data[2], &path_buffer) orelse return -7;
    const span = session_span(session, in.data[3], @sizeOf(proto.filesystem.Stat)) orelse return -7;

    const stat_info = volume.stat(path) catch |failure| return status_of(failure);

    const record = proto.filesystem.Stat{

        .kind = @intFromEnum(stat_info.kind),
        .permissions = stat_info.permissions,

        .length = stat_info.length,

        .created_ns = stat_info.created_ns,
        .modified_ns = stat_info.modified_ns,

    };

    @memcpy(span[0..@sizeOf(proto.filesystem.Stat)], std.mem.asBytes(&record));

    return 0;

}

fn set_permissions(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;

    var path_buffer: [max_path]u8 = undefined;
    const path = copy_path(session, in.data[1], in.data[2], &path_buffer) orelse return -7;

    volume.set_permissions(path, @truncate(in.data[3])) catch |failure| return status_of(failure);

    return 0;

}

fn info(badge: u64, in: *const Message) i64 {

    const session = session_for(badge) orelse return -7;
    const span = session_span(session, in.data[1], @sizeOf(proto.filesystem.Info)) orelse return -7;
    const space = volume.space_info() catch |failure| return status_of(failure);

    const record = proto.filesystem.Info{

        .sector_size = @intCast(proto.block.sector_size),
        .sectors_per_block = @intCast(sectors_per_block),
        .block_size = @intCast(block_size),
        .block_count = space.block_count,

        .used_blocks = space.used_blocks,
        .free_blocks = space.free_blocks,
        .inode_count = space.inode_count,
        .reserved = 0,

    };

    @memcpy(span[0..@sizeOf(proto.filesystem.Info)], std.mem.asBytes(&record));

    return 0;

}

// Shared path-taking shapes

fn do_create(path: []const u8, kind: format.Kind) format.Error!void {

    _ = try volume.create(path, kind);

}

fn do_delete(path: []const u8, kind: format.Kind) format.Error!void {

    _ = kind;

    try volume.delete(path);

}

fn path_call(badge: u64, in: *const Message, kind: format.Kind, action: *const fn ([]const u8, format.Kind) format.Error!void) i64 {

    const session = session_for(badge) orelse return -7;

    var path_buffer: [max_path]u8 = undefined;
    const path = copy_path(session, in.data[1], in.data[2], &path_buffer) orelse return -7;

    action(path, kind) catch |failure| return status_of(failure);

    return 0;

}

// Session plumbing

fn session_for(badge: u64) ?*Session {

    return sessions.find(badge);

}

fn file_for(badge: u64, id: u64) ?*OpenFile {

    const session = session_for(badge) orelse return null;

    if (id >= max_open_files) return null;

    const file = &session.extra.table[@intCast(id)];

    return if (file.used) file else null;

}

fn session_span(session: *Session, offset: u64, length: u64) ?[]u8 {

    if (session.base == 0) return null;
    if (offset > session.capacity or length > session.capacity - offset) return null;

    const bytes: [*]u8 = @ptrFromInt(session.base);

    return bytes[@intCast(offset)..@intCast(offset + length)];

}

// Requests reference the shared buffer, which the client owns; copy the path out so it stays stable mid-request.

fn copy_path(session: *Session, offset: u64, length: u64, buffer: *[max_path]u8) ?[]const u8 {

    if (length == 0 or length > max_path) return null;

    const span = session_span(session, offset, length) orelse return null;

    @memcpy(buffer[0..span.len], span);

    return buffer[0..span.len];

}

// The shared error codes (05-server-protocol.md): servers never invent their own numbering.

fn status_of(failure: format.Error) i64 {

    return switch (failure) {

        error.NoSpace => -3,
        error.NotAllowed => -4,
        error.NotFound => -6,
        error.Invalid, error.NotEmpty, error.Exists, error.NameTooLong => -7,
        error.Io => -8,

    };

}

fn log(comptime text: []const u8, args: anytype) void {

    lib.log.fmt(text, args);

}
