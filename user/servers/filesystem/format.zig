// Strata: the GraniteOS on-disk format (07-userspace-ddd.md Section 7.1) - a conventional indexed filesystem:
// superblock, block bitmap, inode table, data blocks. Directories are files of fixed-size {name, inode} records;
// large files grow through single- and double-indirect blocks. All writes are write-through (decision #19 v1).
//
// This module is pure format logic over a generic block device, so it is host-testable (zig build test); the
// server (main.zig) supplies a device backed by the block driver and its cache.

const std = @import("std");

pub const block_size = 4096;
pub const magic: u32 = 0x4152_5453; // "STRA"
pub const format_version: u32 = 1;

pub const inode_size = 128;
pub const inodes_per_block = block_size / inode_size;
pub const pointers_per_block = block_size / 4;

pub const direct_blocks = 12;
pub const max_name = 48;
pub const root_inode: u32 = 1;

pub const Kind = enum(u8) {

    none = 0,
    file = 1,
    directory = 2,

};

// permissions bit 0: writable. More bits are format-compatible later.

pub const permission_write: u16 = 1;
pub const default_permissions: u16 = permission_write;

pub const Error = error{

    NoSpace,
    NotFound,
    Invalid,
    NotAllowed,
    NotEmpty,
    Exists,
    NameTooLong,
    Io,

};

pub const Superblock = extern struct {

    magic: u32,
    version: u32,

    block_count: u32,
    inode_count: u32,

    bitmap_start: u32,
    bitmap_blocks: u32,
    inode_start: u32,
    inode_blocks: u32,
    data_start: u32,

    root: u32,

};

pub const Inode = extern struct {

    kind: u16,
    permissions: u16,
    owner: u32,

    length: u64,

    created_ns: u64,
    modified_ns: u64,

    direct: [direct_blocks]u32,
    indirect: u32,
    double_indirect: u32,

    reserved: [40]u8,

};

pub const DirEntry = extern struct {

    inode: u32,

    kind: u8,
    name_len: u8,
    reserved: [10]u8,

    name: [max_name]u8,

};

pub const entries_per_block = block_size / @sizeOf(DirEntry);

pub const StatInfo = struct {

    kind: Kind,
    permissions: u16,

    length: u64,

    created_ns: u64,
    modified_ns: u64,

};

pub const ListEntry = struct {

    inode: u32,
    kind: Kind,

    length: u64,

    name_len: u8,
    name: [max_name]u8,

};

comptime {

    std.debug.assert(@sizeOf(Inode) == inode_size);
    std.debug.assert(@sizeOf(DirEntry) == 64);
    std.debug.assert(@sizeOf(Superblock) <= block_size);

}

const inode_cache_slots = 32;
const name_cache_slots = 64;

/// The volume logic over a `Device` providing `read_block`, `write_block`, and `block_count`.
pub fn Volume(comptime Device: type) type {

    return struct {

        device: *Device,
        super: Superblock,

        // In-memory caches (07-userspace-ddd.md Section 7.2), both direct-mapped and write-through.

        inode_cache: [inode_cache_slots]InodeCacheEntry,
        name_cache: [name_cache_slots]NameCacheEntry,

        const Self = @This();

        const InodeCacheEntry = struct {

            number: u32 = 0,
            valid: bool = false,
            inode: Inode = undefined,

        };

        const NameCacheEntry = struct {

            dir: u32 = 0,
            child: u32 = 0,

            kind: u8 = 0,
            len: u8 = 0,
            valid: bool = false,

            name: [max_name]u8 = undefined,

        };

        /// Mount an existing Strata volume; `error.Invalid` means the disk holds no recognizable format.
        pub fn open(device: *Device) Error!Self {

            var block: [block_size]u8 = undefined;

            device.read_block(0, &block) catch return error.Io;

            const super = std.mem.bytesToValue(Superblock, block[0..@sizeOf(Superblock)]);

            if (super.magic != magic or super.version != format_version) return error.Invalid;
            if (super.block_count == 0 or super.block_count > device.block_count()) return error.Invalid;

            return started(device, super);

        }

        /// Write a fresh, empty volume across the whole device.
        pub fn format(device: *Device) Error!Self {

            const blocks = device.block_count();

            if (blocks < 16) return error.Invalid;

            const inode_count: u32 = @intCast(std.math.clamp(blocks / 8, 64, 2048));
            const bitmap_blocks: u32 = @intCast((blocks + block_size * 8 - 1) / (block_size * 8));
            const inode_blocks: u32 = @intCast((inode_count + inodes_per_block - 1) / inodes_per_block);

            const super = Superblock{

                .magic = magic,
                .version = format_version,

                .block_count = @intCast(blocks),
                .inode_count = inode_count,

                .bitmap_start = 1,
                .bitmap_blocks = bitmap_blocks,
                .inode_start = 1 + bitmap_blocks,
                .inode_blocks = inode_blocks,
                .data_start = 1 + bitmap_blocks + inode_blocks,

                .root = root_inode,

            };

            if (super.data_start >= super.block_count) return error.Invalid;

            var self = started(device, super);
            var block = [_]u8{0} ** block_size;

            // Zero the bitmap and inode table, then reserve every metadata block in the bitmap.

            var index: u32 = super.bitmap_start;

            while (index < super.data_start) : (index += 1) {

                try self.write_device(index, &block);

            }

            var reserved: u32 = 0;

            while (reserved < super.data_start) : (reserved += 1) {

                try self.bitmap_set(reserved, true);

            }

            var root = std.mem.zeroes(Inode);

            root.kind = @intFromEnum(Kind.directory);
            root.permissions = default_permissions;

            try self.write_inode(root_inode, &root);

            @memcpy(block[0..@sizeOf(Superblock)], std.mem.asBytes(&super));
            try self.write_device(0, &block);

            return self;

        }

        fn started(device: *Device, super: Superblock) Self {

            return .{

                .device = device,
                .super = super,

                .inode_cache = [_]InodeCacheEntry{.{}} ** inode_cache_slots,
                .name_cache = [_]NameCacheEntry{.{}} ** name_cache_slots,

            };

        }

        // Public operations, all path-stateless (paths are absolute; the caller tracks any cwd).

        pub fn resolve(self: *Self, path: []const u8) Error!u32 {

            if (path.len == 0 or path[0] != '/') return error.Invalid;

            var current = self.super.root;
            var components = std.mem.tokenizeScalar(u8, path, '/');

            while (components.next()) |name| {

                current = try self.lookup_child(current, name);

            }

            return current;

        }

        pub fn create(self: *Self, path: []const u8, kind: Kind) Error!u32 {

            const location = try self.resolve_parent(path);

            if (self.lookup_child(location.dir, location.name)) |_| {

                return error.Exists;

            } else |failure| {

                if (failure != error.NotFound) return failure;

            }

            const number = try self.alloc_inode();

            var inode = std.mem.zeroes(Inode);

            inode.kind = @intFromEnum(kind);
            inode.permissions = default_permissions;

            try self.write_inode(number, &inode);
            try self.dir_add(location.dir, location.name, number, kind);

            return number;

        }

        pub fn delete(self: *Self, path: []const u8) Error!void {

            const location = try self.resolve_parent(path);
            const child = try self.lookup_child(location.dir, location.name);

            var inode = try self.read_inode(child);

            if (inode.permissions & permission_write == 0) return error.NotAllowed;

            if (inode.kind == @intFromEnum(Kind.directory)) {

                if (!try self.dir_is_empty(&inode)) return error.NotEmpty;

            }

            try self.free_file_blocks(&inode);

            inode = std.mem.zeroes(Inode);
            try self.write_inode(child, &inode);

            try self.dir_remove(location.dir, location.name);

        }

        pub fn rename(self: *Self, old: []const u8, new: []const u8) Error!void {

            // Moving a directory into its own subtree would orphan it.

            if (new.len > old.len and std.mem.startsWith(u8, new, old) and new[old.len] == '/') return error.Invalid;

            const from = try self.resolve_parent(old);
            const child = try self.lookup_child(from.dir, from.name);
            const inode = try self.read_inode(child);

            const to = try self.resolve_parent(new);

            if (self.lookup_child(to.dir, to.name)) |_| {

                return error.Exists;

            } else |failure| {

                if (failure != error.NotFound) return failure;

            }

            try self.dir_add(to.dir, to.name, child, @enumFromInt(inode.kind));
            try self.dir_remove(from.dir, from.name);

        }

        pub fn stat(self: *Self, path: []const u8) Error!StatInfo {

            const number = try self.resolve(path);
            const inode = try self.read_inode(number);

            return .{

                .kind = @enumFromInt(inode.kind),
                .permissions = inode.permissions,

                .length = inode.length,

                .created_ns = inode.created_ns,
                .modified_ns = inode.modified_ns,

            };

        }

        pub fn set_permissions(self: *Self, path: []const u8, mask: u16) Error!void {

            const number = try self.resolve(path);
            var inode = try self.read_inode(number);

            inode.permissions = mask;

            try self.write_inode(number, &inode);

        }

        pub fn list(self: *Self, path: []const u8, out: []ListEntry) Error!usize {

            const number = try self.resolve(path);
            var dir = try self.read_inode(number);

            if (dir.kind != @intFromEnum(Kind.directory)) return error.Invalid;

            var found: usize = 0;
            var offset: u64 = 0;

            while (offset < dir.length and found < out.len) : (offset += @sizeOf(DirEntry)) {

                const entry = try self.dir_entry_at(&dir, offset);

                if (entry.inode == 0) continue;

                const child = try self.read_inode(entry.inode);

                out[found] = .{

                    .inode = entry.inode,
                    .kind = @enumFromInt(entry.kind),

                    .length = child.length,

                    .name_len = entry.name_len,
                    .name = entry.name,

                };

                found += 1;

            }

            return found;

        }

        pub fn kind_of(self: *Self, number: u32) Error!Kind {

            const inode = try self.read_inode(number);

            return @enumFromInt(inode.kind);

        }

        pub fn read(self: *Self, number: u32, offset: u64, out: []u8) Error!usize {

            var inode = try self.read_inode(number);

            if (inode.kind != @intFromEnum(Kind.file)) return error.Invalid;
            if (offset >= inode.length) return 0;

            const amount: usize = @intCast(@min(out.len, inode.length - offset));

            var block: [block_size]u8 = undefined;
            var done: usize = 0;

            while (done < amount) {

                const at = offset + done;
                const in_block: usize = @intCast(at % block_size);
                const chunk = @min(amount - done, block_size - in_block);

                const mapped = try self.map_block(&inode, number, @intCast(at / block_size), false);

                if (mapped == 0) {

                    @memset(out[done .. done + chunk], 0);

                } else {

                    try self.read_device(mapped, &block);
                    @memcpy(out[done .. done + chunk], block[in_block .. in_block + chunk]);

                }

                done += chunk;

            }

            return amount;

        }

        pub fn write(self: *Self, number: u32, offset: u64, bytes: []const u8) Error!usize {

            var inode = try self.read_inode(number);

            if (inode.kind != @intFromEnum(Kind.file)) return error.Invalid;
            if (inode.permissions & permission_write == 0) return error.NotAllowed;

            var block: [block_size]u8 = undefined;
            var done: usize = 0;

            while (done < bytes.len) {

                const at = offset + done;
                const in_block: usize = @intCast(at % block_size);
                const chunk = @min(bytes.len - done, block_size - in_block);

                const mapped = try self.map_block(&inode, number, @intCast(at / block_size), true);

                if (chunk < block_size) {

                    try self.read_device(mapped, &block);

                }

                @memcpy(block[in_block .. in_block + chunk], bytes[done .. done + chunk]);
                try self.write_device(mapped, &block);

                done += chunk;

            }

            if (offset + bytes.len > inode.length) {

                inode.length = offset + bytes.len;

            }

            try self.write_inode(number, &inode);

            return bytes.len;

        }

        pub fn truncate(self: *Self, number: u32) Error!void {

            var inode = try self.read_inode(number);

            if (inode.kind != @intFromEnum(Kind.file)) return error.Invalid;
            if (inode.permissions & permission_write == 0) return error.NotAllowed;

            const permissions = inode.permissions;

            try self.free_file_blocks(&inode);

            inode = std.mem.zeroes(Inode);
            inode.kind = @intFromEnum(Kind.file);
            inode.permissions = permissions;

            try self.write_inode(number, &inode);

        }

        // Path helpers

        const ParentLocation = struct {

            dir: u32,
            name: []const u8,

        };

        fn resolve_parent(self: *Self, path: []const u8) Error!ParentLocation {

            if (path.len == 0 or path[0] != '/') return error.Invalid;

            const trimmed = std.mem.trimRight(u8, path, "/");

            if (trimmed.len == 0) return error.Invalid; // the root itself has no parent entry

            const split = std.mem.lastIndexOfScalar(u8, trimmed, '/').?;
            const name = trimmed[split + 1 ..];

            if (name.len == 0) return error.Invalid;
            if (name.len > max_name) return error.NameTooLong;

            const dir = try self.resolve(if (split == 0) "/" else trimmed[0..split]);

            if (try self.kind_of(dir) != .directory) return error.Invalid;

            return .{

                .dir = dir,
                .name = name,

            };

        }

        fn lookup_child(self: *Self, dir: u32, name: []const u8) Error!u32 {

            if (name.len == 0 or name.len > max_name) return error.NotFound;

            const slot = &self.name_cache[name_slot(dir, name)];

            if (slot.valid and slot.dir == dir and std.mem.eql(u8, slot.name[0..slot.len], name)) {

                return slot.child;

            }

            var inode = try self.read_inode(dir);

            if (inode.kind != @intFromEnum(Kind.directory)) return error.NotFound;

            var offset: u64 = 0;

            while (offset < inode.length) : (offset += @sizeOf(DirEntry)) {

                const entry = try self.dir_entry_at(&inode, offset);

                if (entry.inode == 0) continue;
                if (!std.mem.eql(u8, entry.name[0..entry.name_len], name)) continue;

                slot.* = .{

                    .dir = dir,
                    .child = entry.inode,

                    .kind = entry.kind,
                    .len = entry.name_len,
                    .valid = true,

                    .name = entry.name,

                };

                return entry.inode;

            }

            return error.NotFound;

        }

        fn invalidate_dir(self: *Self, dir: u32) void {

            for (&self.name_cache) |*entry| {

                if (entry.dir == dir) entry.valid = false;

            }

        }

        fn name_slot(dir: u32, name: []const u8) usize {

            var hash: u32 = dir;

            for (name) |byte| {

                hash = hash *% 31 +% byte;

            }

            return hash % name_cache_slots;

        }

        // Directory storage

        fn dir_entry_at(self: *Self, dir: *Inode, offset: u64) Error!DirEntry {

            var block: [block_size]u8 = undefined;

            const mapped = try self.map_block(dir, 0, @intCast(offset / block_size), false);

            if (mapped == 0) return std.mem.zeroes(DirEntry);

            try self.read_device(mapped, &block);

            const in_block: usize = @intCast(offset % block_size);

            return std.mem.bytesToValue(DirEntry, block[in_block..][0..@sizeOf(DirEntry)]);

        }

        fn dir_put_entry(self: *Self, dir: *Inode, number: u32, offset: u64, entry: *const DirEntry) Error!void {

            var block: [block_size]u8 = undefined;

            const mapped = try self.map_block(dir, number, @intCast(offset / block_size), true);

            try self.read_device(mapped, &block);

            const in_block: usize = @intCast(offset % block_size);

            @memcpy(block[in_block..][0..@sizeOf(DirEntry)], std.mem.asBytes(entry));
            try self.write_device(mapped, &block);

        }

        fn dir_add(self: *Self, dir: u32, name: []const u8, child: u32, kind: Kind) Error!void {

            if (name.len > max_name) return error.NameTooLong;

            var inode = try self.read_inode(dir);

            var entry = std.mem.zeroes(DirEntry);

            entry.inode = child;
            entry.kind = @intFromEnum(kind);
            entry.name_len = @intCast(name.len);
            @memcpy(entry.name[0..name.len], name);

            // Reuse the first hole; otherwise append and grow the directory by one record.

            var offset: u64 = 0;

            while (offset < inode.length) : (offset += @sizeOf(DirEntry)) {

                const existing = try self.dir_entry_at(&inode, offset);

                if (existing.inode == 0) break;

            }

            try self.dir_put_entry(&inode, dir, offset, &entry);

            if (offset >= inode.length) {

                inode.length = offset + @sizeOf(DirEntry);

            }

            try self.write_inode(dir, &inode);

            self.invalidate_dir(dir);

        }

        fn dir_remove(self: *Self, dir: u32, name: []const u8) Error!void {

            var inode = try self.read_inode(dir);
            var offset: u64 = 0;

            while (offset < inode.length) : (offset += @sizeOf(DirEntry)) {

                const entry = try self.dir_entry_at(&inode, offset);

                if (entry.inode == 0) continue;
                if (!std.mem.eql(u8, entry.name[0..entry.name_len], name)) continue;

                const hole = std.mem.zeroes(DirEntry);

                try self.dir_put_entry(&inode, dir, offset, &hole);

                self.invalidate_dir(dir);

                return;

            }

            return error.NotFound;

        }

        fn dir_is_empty(self: *Self, dir: *Inode) Error!bool {

            var offset: u64 = 0;

            while (offset < dir.length) : (offset += @sizeOf(DirEntry)) {

                const entry = try self.dir_entry_at(dir, offset);

                if (entry.inode != 0) return false;

            }

            return true;

        }

        // Block mapping: direct, then single-indirect, then double-indirect (07-userspace-ddd.md Section 7.1).
        // With `allocate`, missing blocks (and missing indirect blocks) are claimed and the inode is persisted.

        fn map_block(self: *Self, inode: *Inode, number: u32, file_block: u32, allocate: bool) Error!u32 {

            var dirty = false;
            defer if (dirty) {

                self.write_inode(number, inode) catch {};

            };

            if (file_block < direct_blocks) {

                if (inode.direct[file_block] == 0 and allocate) {

                    inode.direct[file_block] = try self.alloc_block();
                    dirty = true;

                }

                return inode.direct[file_block];

            }

            const single = file_block - direct_blocks;

            if (single < pointers_per_block) {

                if (inode.indirect == 0) {

                    if (!allocate) return 0;

                    inode.indirect = try self.alloc_block();
                    dirty = true;

                }

                return self.indirect_slot(inode.indirect, single, allocate);

            }

            const double = single - pointers_per_block;

            if (double >= pointers_per_block * pointers_per_block) return error.NoSpace;

            if (inode.double_indirect == 0) {

                if (!allocate) return 0;

                inode.double_indirect = try self.alloc_block();
                dirty = true;

            }

            const level_one = try self.indirect_slot(inode.double_indirect, double / pointers_per_block, allocate);

            if (level_one == 0) return 0;

            return self.indirect_slot(level_one, double % pointers_per_block, allocate);

        }

        fn indirect_slot(self: *Self, table: u32, index: u32, allocate: bool) Error!u32 {

            var block: [block_size]u8 = undefined;

            try self.read_device(table, &block);

            const pointers = std.mem.bytesAsSlice(u32, &block);

            if (pointers[index] == 0 and allocate) {

                pointers[index] = try self.alloc_block();
                try self.write_device(table, &block);

            }

            return pointers[index];

        }

        fn free_file_blocks(self: *Self, inode: *Inode) Error!void {

            for (inode.direct) |direct| {

                if (direct != 0) try self.bitmap_set(direct, false);

            }

            if (inode.indirect != 0) try self.free_indirect(inode.indirect, 1);
            if (inode.double_indirect != 0) try self.free_indirect(inode.double_indirect, 2);

        }

        fn free_indirect(self: *Self, table: u32, depth: u32) Error!void {

            var block: [block_size]u8 = undefined;

            try self.read_device(table, &block);

            const pointers = std.mem.bytesAsSlice(u32, &block);

            for (pointers) |pointer| {

                if (pointer == 0) continue;

                if (depth > 1) {

                    try self.free_indirect(pointer, depth - 1);

                } else {

                    try self.bitmap_set(pointer, false);

                }

            }

            try self.bitmap_set(table, false);

        }

        // Allocation

        fn alloc_block(self: *Self) Error!u32 {

            var block: [block_size]u8 = undefined;
            var bitmap_index: u32 = 0;

            while (bitmap_index < self.super.bitmap_blocks) : (bitmap_index += 1) {

                try self.read_device(self.super.bitmap_start + bitmap_index, &block);

                for (&block, 0..) |*byte, byte_index| {

                    if (byte.* == 0xff) continue;

                    const bit: u3 = @intCast(@ctz(~byte.*));
                    const found: u32 = @intCast((bitmap_index * block_size + byte_index) * 8 + bit);

                    if (found >= self.super.block_count) return error.NoSpace;

                    byte.* |= @as(u8, 1) << bit;
                    try self.write_device(self.super.bitmap_start + bitmap_index, &block);

                    // Hand out zeroed blocks so stale data never leaks into files or directories.

                    const zeroes = [_]u8{0} ** block_size;
                    try self.write_device(found, &zeroes);

                    return found;

                }

            }

            return error.NoSpace;

        }

        fn bitmap_set(self: *Self, index: u32, used: bool) Error!void {

            var block: [block_size]u8 = undefined;

            const holder = self.super.bitmap_start + index / (block_size * 8);
            const in_block = (index / 8) % block_size;
            const bit: u3 = @intCast(index % 8);

            try self.read_device(holder, &block);

            if (used) {

                block[in_block] |= @as(u8, 1) << bit;

            } else {

                block[in_block] &= ~(@as(u8, 1) << bit);

            }

            try self.write_device(holder, &block);

        }

        fn alloc_inode(self: *Self) Error!u32 {

            var block: [block_size]u8 = undefined;
            var table_index: u32 = 0;

            while (table_index < self.super.inode_blocks) : (table_index += 1) {

                try self.read_device(self.super.inode_start + table_index, &block);

                for (0..inodes_per_block) |slot| {

                    const number: u32 = @intCast(table_index * inodes_per_block + slot);

                    if (number <= root_inode) continue; // 0 is the null inode, 1 the root
                    if (number >= self.super.inode_count) return error.NoSpace;

                    const inode = std.mem.bytesToValue(Inode, block[slot * inode_size ..][0..inode_size]);

                    if (inode.kind == @intFromEnum(Kind.none)) return number;

                }

            }

            return error.NoSpace;

        }

        // Inode storage (write-through cache)

        fn read_inode(self: *Self, number: u32) Error!Inode {

            if (number == 0 or number >= self.super.inode_count) return error.Invalid;

            const slot = &self.inode_cache[number % inode_cache_slots];

            if (slot.valid and slot.number == number) return slot.inode;

            var block: [block_size]u8 = undefined;

            try self.read_device(self.super.inode_start + number / inodes_per_block, &block);

            const inode = std.mem.bytesToValue(Inode, block[(number % inodes_per_block) * inode_size ..][0..inode_size]);

            slot.* = .{

                .number = number,
                .valid = true,
                .inode = inode,

            };

            return inode;

        }

        fn write_inode(self: *Self, number: u32, inode: *const Inode) Error!void {

            if (number == 0 or number >= self.super.inode_count) return error.Invalid;

            var block: [block_size]u8 = undefined;

            const holder = self.super.inode_start + number / inodes_per_block;

            try self.read_device(holder, &block);

            @memcpy(block[(number % inodes_per_block) * inode_size ..][0..inode_size], std.mem.asBytes(inode));

            try self.write_device(holder, &block);

            self.inode_cache[number % inode_cache_slots] = .{

                .number = number,
                .valid = true,
                .inode = inode.*,

            };

        }

        // Device pass-through

        fn read_device(self: *Self, index: u32, out: *[block_size]u8) Error!void {

            self.device.read_block(index, out) catch return error.Io;

        }

        fn write_device(self: *Self, index: u32, data: *const [block_size]u8) Error!void {

            self.device.write_block(index, data) catch return error.Io;

        }

    };

}

// Host tests over an in-memory device.

const testing = std.testing;

const MemoryDevice = struct {

    storage: [][block_size]u8,

    fn read_block(self: *MemoryDevice, index: u32, out: *[block_size]u8) !void {

        out.* = self.storage[index];

    }

    fn write_block(self: *MemoryDevice, index: u32, data: *const [block_size]u8) !void {

        self.storage[index] = data.*;

    }

    fn block_count(self: *MemoryDevice) u32 {

        return @intCast(self.storage.len);

    }

};

const TestVolume = Volume(MemoryDevice);

fn test_device(blocks: usize) !MemoryDevice {

    const storage = try testing.allocator.alloc([block_size]u8, blocks);

    for (storage) |*block| {

        @memset(block, 0);

    }

    return .{ .storage = storage };

}

test "format then open finds the same geometry and an empty root" {

    var device = try test_device(256);
    defer testing.allocator.free(device.storage);

    const formatted = try TestVolume.format(&device);

    try testing.expectEqual(@as(u32, 256), formatted.super.block_count);

    var reopened = try TestVolume.open(&device);

    try testing.expectEqual(formatted.super.data_start, reopened.super.data_start);

    var entries: [4]ListEntry = undefined;

    try testing.expectEqual(@as(usize, 0), try reopened.list("/", &entries));

}

test "open rejects a blank disk" {

    var device = try test_device(64);
    defer testing.allocator.free(device.storage);

    try testing.expectError(error.Invalid, TestVolume.open(&device));

}

test "files persist across a remount" {

    var device = try test_device(256);
    defer testing.allocator.free(device.storage);

    {

        var volume = try TestVolume.format(&device);

        _ = try volume.create("/docs", .directory);

        const file = try volume.create("/docs/notes", .file);
        _ = try volume.write(file, 0, "persist-me");

    }

    var volume = try TestVolume.open(&device);

    const number = try volume.resolve("/docs/notes");
    var buffer: [32]u8 = undefined;

    const length = try volume.read(number, 0, &buffer);

    try testing.expectEqualStrings("persist-me", buffer[0..length]);

    const info = try volume.stat("/docs/notes");

    try testing.expectEqual(@as(u64, 10), info.length);
    try testing.expectEqual(Kind.file, info.kind);

}

test "large files span the indirect blocks" {

    var device = try test_device(512);
    defer testing.allocator.free(device.storage);

    var volume = try TestVolume.format(&device);

    const file = try volume.create("/big", .file);

    // 64 KiB crosses the 48 KiB direct-block boundary into the single-indirect region.

    var chunk: [block_size]u8 = undefined;
    var index: u64 = 0;

    while (index < 16) : (index += 1) {

        @memset(&chunk, @as(u8, @intCast(index + 1)));
        _ = try volume.write(file, index * block_size, &chunk);

    }

    var back: [block_size]u8 = undefined;

    _ = try volume.read(file, 13 * block_size, &back);
    try testing.expectEqual(@as(u8, 14), back[0]);
    try testing.expectEqual(@as(u8, 14), back[block_size - 1]);

    const info = try volume.stat("/big");
    try testing.expectEqual(@as(u64, 16 * block_size), info.length);

}

test "delete refuses a populated directory and reclaims file blocks" {

    var device = try test_device(256);
    defer testing.allocator.free(device.storage);

    var volume = try TestVolume.format(&device);

    _ = try volume.create("/dir", .directory);
    const file = try volume.create("/dir/a", .file);
    _ = try volume.write(file, 0, "abc");

    try testing.expectError(error.NotEmpty, volume.delete("/dir"));

    try volume.delete("/dir/a");
    try testing.expectError(error.NotFound, volume.resolve("/dir/a"));

    try volume.delete("/dir");
    try testing.expectError(error.NotFound, volume.resolve("/dir"));

}

test "rename moves an entry between directories" {

    var device = try test_device(256);
    defer testing.allocator.free(device.storage);

    var volume = try TestVolume.format(&device);

    _ = try volume.create("/a", .directory);
    _ = try volume.create("/b", .directory);

    const file = try volume.create("/a/file", .file);
    _ = try volume.write(file, 0, "moved");

    try volume.rename("/a/file", "/b/renamed");

    try testing.expectError(error.NotFound, volume.resolve("/a/file"));

    var buffer: [16]u8 = undefined;
    const number = try volume.resolve("/b/renamed");
    const length = try volume.read(number, 0, &buffer);

    try testing.expectEqualStrings("moved", buffer[0..length]);

    try testing.expectError(error.Invalid, volume.rename("/b", "/b/renamed/inside"));

}

test "clearing the write permission blocks writes and deletes" {

    var device = try test_device(256);
    defer testing.allocator.free(device.storage);

    var volume = try TestVolume.format(&device);

    const file = try volume.create("/locked", .file);
    _ = try volume.write(file, 0, "safe");

    try volume.set_permissions("/locked", 0);

    try testing.expectError(error.NotAllowed, volume.write(file, 0, "clobber"));
    try testing.expectError(error.NotAllowed, volume.delete("/locked"));

    try volume.set_permissions("/locked", default_permissions);
    try volume.delete("/locked");

}

test "creating over an existing name reports Exists" {

    var device = try test_device(256);
    defer testing.allocator.free(device.storage);

    var volume = try TestVolume.format(&device);

    _ = try volume.create("/twice", .file);
    try testing.expectError(error.Exists, volume.create("/twice", .file));

}
