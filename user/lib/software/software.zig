// Granite Software repository records, package verification, and transactional installs.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const config = @import("../fs/config.zig");
const fs = @import("../fs/fs.zig");
const layout = @import("../fs/layout.zig");
const mem = @import("../mem/mem.zig");
const proto = @import("../ipc/proto.zig");
const sys = @import("../syscall/sys.zig");

pub const protocol_version: u32 = 1;
pub const abi = "gos2-aarch64-v1";
pub const default_repository = "https://repo.graniteos.org/v1/index.json";

pub const max_packages = 64;
pub const max_binary = 1024 * 1024;
pub const max_catalog_bytes = 32 * 1024;

const catalog_name = "software-catalog";
const repository_name = "software-repository";

pub const Error = config.Error || error{
    InvalidRepository,
    InvalidPackage,
    Incompatible,
    HashMismatch,
    TooLarge,
    BuiltinConflict,
};

pub const Package = struct {

    id: [32]u8 = [_]u8{0} ** 32,
    id_len: u8 = 0,
    name: [40]u8 = [_]u8{0} ** 40,
    name_len: u8 = 0,
    summary: [80]u8 = [_]u8{0} ** 80,
    summary_len: u8 = 0,
    version: [24]u8 = [_]u8{0} ** 24,
    version_len: u8 = 0,
    category: [24]u8 = [_]u8{0} ** 24,
    category_len: u8 = 0,
    icon: [24]u8 = [_]u8{0} ** 24,
    icon_len: u8 = 0,
    artifact: [256]u8 = [_]u8{0} ** 256,
    artifact_len: u16 = 0,
    sha256: [64]u8 = [_]u8{0} ** 64,
    bytes: usize = 0,

    pub fn program(self: *const Package) []const u8 {

        return self.id[0..self.id_len];

    }

    pub fn title(self: *const Package) []const u8 {

        return self.name[0..self.name_len];

    }

    pub fn description(self: *const Package) []const u8 {

        return self.summary[0..self.summary_len];

    }

    pub fn release(self: *const Package) []const u8 {

        return self.version[0..self.version_len];

    }

    pub fn group(self: *const Package) []const u8 {

        return self.category[0..self.category_len];

    }

    pub fn icon_name(self: *const Package) []const u8 {

        return self.icon[0..self.icon_len];

    }

    pub fn url(self: *const Package) []const u8 {

        return self.artifact[0..self.artifact_len];

    }

};

pub const Installed = struct {

    id: [32]u8 = [_]u8{0} ** 32,
    id_len: u8 = 0,
    name: [40]u8 = [_]u8{0} ** 40,
    name_len: u8 = 0,
    summary: [80]u8 = [_]u8{0} ** 80,
    summary_len: u8 = 0,
    version: [24]u8 = [_]u8{0} ** 24,
    version_len: u8 = 0,
    category: [24]u8 = [_]u8{0} ** 24,
    category_len: u8 = 0,
    icon: [24]u8 = [_]u8{0} ** 24,
    icon_len: u8 = 0,
    sha256: [64]u8 = [_]u8{0} ** 64,

    pub fn program(self: *const Installed) []const u8 {

        return self.id[0..self.id_len];

    }

    pub fn title(self: *const Installed) []const u8 {

        return self.name[0..self.name_len];

    }

    pub fn description(self: *const Installed) []const u8 {

        return self.summary[0..self.summary_len];

    }

    pub fn release(self: *const Installed) []const u8 {

        return self.version[0..self.version_len];

    }

    pub fn group(self: *const Installed) []const u8 {

        return self.category[0..self.category_len];

    }

    pub fn icon_name(self: *const Installed) []const u8 {

        return self.icon[0..self.icon_len];

    }

};

const WireIndex = struct {

    protocol: u32,
    packages: []const WirePackage,

};

const WirePackage = struct {

    id: []const u8,
    name: []const u8,
    summary: []const u8,
    version: []const u8,
    category: []const u8,
    icon: []const u8,
    artifact: []const u8,
    sha256: []const u8,
    bytes: usize,
    abi: []const u8,

};

pub fn parse_index(heap: *mem.Heap, body: []const u8, out: []Package) Error!usize {

    const parsed = std.json.parseFromSlice(WireIndex, heap.allocator(), body, .{

        .ignore_unknown_fields = true,

    }) catch return error.InvalidRepository;
    defer parsed.deinit();

    if (parsed.value.protocol != protocol_version) return error.Incompatible;
    if (parsed.value.packages.len > out.len) return error.TooLarge;

    var count: usize = 0;

    for (parsed.value.packages) |wire| {

        if (!std.mem.eql(u8, wire.abi, abi)) continue;

        var package = Package{};

        copy_field(&package.id, &package.id_len, wire.id) catch continue;
        copy_field(&package.name, &package.name_len, wire.name) catch continue;
        copy_field(&package.summary, &package.summary_len, wire.summary) catch continue;
        copy_field(&package.version, &package.version_len, wire.version) catch continue;
        copy_field(&package.category, &package.category_len, wire.category) catch continue;
        copy_field(&package.icon, &package.icon_len, wire.icon) catch continue;
        copy_field_u16(&package.artifact, &package.artifact_len, wire.artifact) catch continue;

        if (!valid_id(package.program())) continue;
        if (wire.sha256.len != package.sha256.len) continue;
        if (wire.bytes == 0 or wire.bytes > max_binary) continue;
        if (!valid_https_url(package.url())) continue;
        if (!valid_hash(wire.sha256)) continue;

        for (wire.sha256, 0..) |byte, index| {

            package.sha256[index] = std.ascii.toLower(byte);

        }

        package.bytes = wire.bytes;
        out[count] = package;
        count += 1;

    }

    return count;

}

pub fn repository_url(out: []u8) []const u8 {

    const configured = config.load(repository_name, out) catch {

        const length = @min(default_repository.len, out.len);

        @memcpy(out[0..length], default_repository[0..length]);

        return out[0..length];

    };

    const trimmed = std.mem.trim(u8, configured, " \t\r\n");

    if (!valid_https_url(trimmed)) return default_repository;

    return trimmed;

}

pub fn save_repository_url(url: []const u8) Error!void {

    if (!valid_https_url(url)) return error.InvalidRepository;

    try config.save(repository_name, url);

}

pub fn load_installed(out: []Installed) usize {

    var buffer: [max_catalog_bytes]u8 = undefined;
    const text = config.load(catalog_name, &buffer) catch return 0;

    return decode_catalog(text, out);

}

pub fn find_installed(items: []const Installed, id: []const u8) ?usize {

    for (items, 0..) |*item, index| {

        if (std.mem.eql(u8, item.program(), id)) return index;

    }

    return null;

}

pub fn install(package: *const Package, image: []const u8) Error!void {

    if (image.len != package.bytes) return error.InvalidPackage;

    try verify_elf(image);
    try verify_hash(image, package.sha256[0..]);

    var installed: [max_packages]Installed = undefined;
    var count = load_installed(installed[0..]);
    const existing = find_installed(installed[0..count], package.program());

    var client = try fs.Client.connect(cap.memory);
    defer client.close();

    layout.ensure(&client);

    var final_path_buffer: [96]u8 = undefined;
    var next_path_buffer: [96]u8 = undefined;
    var old_path_buffer: [96]u8 = undefined;

    const final_path = try app_path(&final_path_buffer, package.program(), "");
    const next_path = try app_path(&next_path_buffer, package.program(), ".next");
    const old_path = try app_path(&old_path_buffer, package.program(), ".old");

    if (existing == null) {

        if (client.stat(final_path)) |_| {

            return error.BuiltinConflict;

        } else |failure| {

            if (failure != error.NotFound) return failure;

        }

    }

    client.delete(next_path) catch {};
    client.delete(old_path) catch {};

    try write_all(&client, next_path, image);

    var moved_old = false;

    if (existing != null) {

        client.rename(final_path, old_path) catch |failure| {

            client.delete(next_path) catch {};
            return failure;

        };

        moved_old = true;

    }

    client.rename(next_path, final_path) catch |failure| {

        if (moved_old) client.rename(old_path, final_path) catch {};

        client.delete(next_path) catch {};
        return failure;

    };

    if (existing) |index| {

        installed[index] = installed_from(package);

    } else {

        if (count >= installed.len) {

            client.delete(final_path) catch {};
            if (moved_old) client.rename(old_path, final_path) catch {};

            return error.TooLarge;

        }

        installed[count] = installed_from(package);
        count += 1;

    }

    save_installed(installed[0..count]) catch |failure| {

        client.delete(final_path) catch {};
        if (moved_old) client.rename(old_path, final_path) catch {};

        return failure;

    };

    client.delete(old_path) catch {};

}

pub fn uninstall(id: []const u8) Error!void {

    var installed: [max_packages]Installed = undefined;
    const count = load_installed(installed[0..]);
    const found = find_installed(installed[0..count], id) orelse return error.NotFound;

    var client = try fs.Client.connect(cap.memory);
    defer client.close();

    var path_buffer: [96]u8 = undefined;
    var remove_buffer: [96]u8 = undefined;
    const path = try app_path(&path_buffer, id, "");
    const remove_path = try app_path(&remove_buffer, id, ".remove");

    client.delete(remove_path) catch {};
    try client.rename(path, remove_path);

    var index = found;

    while (index + 1 < count) : (index += 1) {

        installed[index] = installed[index + 1];

    }

    save_installed(installed[0 .. count - 1]) catch |failure| {

        client.rename(remove_path, path) catch {};

        return failure;

    };

    client.delete(remove_path) catch {};

}

pub fn is_update(package: *const Package, installed: *const Installed) bool {

    return !std.mem.eql(u8, package.release(), installed.release()) or
        !std.mem.eql(u8, package.sha256[0..], installed.sha256[0..]);

}

pub fn verify_elf(image: []const u8) Error!void {

    if (image.len < 64) return error.InvalidPackage;
    if (!std.mem.eql(u8, image[0..4], "\x7fELF")) return error.InvalidPackage;
    if (image[4] != 2 or image[5] != 1 or image[6] != 1) return error.InvalidPackage;

    const elf_type = std.mem.readInt(u16, image[16..18], .little);
    const machine = std.mem.readInt(u16, image[18..20], .little);
    const headers = std.mem.readInt(u16, image[56..58], .little);

    if (elf_type != 2 or machine != 183 or headers == 0) return error.InvalidPackage;

}

fn verify_hash(image: []const u8, expected: []const u8) Error!void {

    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});

    var encoded: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";

    for (digest, 0..) |byte, index| {

        encoded[index * 2] = alphabet[byte >> 4];
        encoded[index * 2 + 1] = alphabet[byte & 0x0f];

    }

    if (!std.mem.eql(u8, &encoded, expected)) return error.HashMismatch;

}

fn installed_from(package: *const Package) Installed {

    var installed = Installed{};

    installed.id = package.id;
    installed.id_len = package.id_len;
    installed.name = package.name;
    installed.name_len = package.name_len;
    installed.summary = package.summary;
    installed.summary_len = package.summary_len;
    installed.version = package.version;
    installed.version_len = package.version_len;
    installed.category = package.category;
    installed.category_len = package.category_len;
    installed.icon = package.icon;
    installed.icon_len = package.icon_len;
    installed.sha256 = package.sha256;

    return installed;

}

fn save_installed(items: []const Installed) Error!void {

    var encoded: [max_catalog_bytes]u8 = undefined;
    var length: usize = 0;

    for (items) |*item| {

        const fields = [_][]const u8{

            item.program(),
            item.release(),
            item.title(),
            item.description(),
            item.icon_name(),
            item.group(),
            item.sha256[0..],

        };

        for (fields, 0..) |field, index| {

            if (length + field.len + 1 > encoded.len) return error.TooLarge;

            @memcpy(encoded[length .. length + field.len], field);
            length += field.len;
            encoded[length] = if (index + 1 == fields.len) '\n' else '\t';
            length += 1;

        }

    }

    try config.save(catalog_name, encoded[0..length]);

}

fn decode_catalog(text: []const u8, out: []Installed) usize {

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {

        if (line.len == 0 or count >= out.len) continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        var item = Installed{};

        const id = fields.next() orelse continue;
        const version = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const summary = fields.next() orelse continue;
        const icon = fields.next() orelse continue;
        const category = fields.next() orelse continue;
        const sha256 = fields.next() orelse continue;

        copy_field(&item.id, &item.id_len, id) catch continue;
        copy_field(&item.version, &item.version_len, version) catch continue;
        copy_field(&item.name, &item.name_len, name) catch continue;
        copy_field(&item.summary, &item.summary_len, summary) catch continue;
        copy_field(&item.icon, &item.icon_len, icon) catch continue;
        copy_field(&item.category, &item.category_len, category) catch continue;

        if (!valid_id(item.program())) continue;
        if (!valid_hash(sha256)) continue;

        @memcpy(item.sha256[0..], sha256);

        out[count] = item;
        count += 1;

    }

    return count;

}

fn write_all(client: *fs.Client, path: []const u8, image: []const u8) Error!void {

    const file = try client.open_path(path, proto.filesystem.open_create | proto.filesystem.open_truncate);
    defer client.close_file(file) catch {};

    var offset: usize = 0;

    while (offset < image.len) {

        const written = try client.write(file, offset, image[offset..]);

        if (written == 0) return error.InvalidPackage;

        offset += written;

    }

}

fn app_path(out: []u8, id: []const u8, suffix: []const u8) Error![]const u8 {

    return std.fmt.bufPrint(out, "{s}/{s}{s}", .{ layout.apps, id, suffix }) catch error.InvalidPackage;

}

fn copy_field(out: []u8, length: *u8, source: []const u8) Error!void {

    if (source.len == 0 or source.len > out.len) return error.InvalidPackage;
    if (!valid_text(source)) return error.InvalidPackage;

    @memcpy(out[0..source.len], source);
    length.* = @intCast(source.len);

}

fn copy_field_u16(out: []u8, length: *u16, source: []const u8) Error!void {

    if (source.len == 0 or source.len > out.len) return error.InvalidPackage;
    if (!valid_text(source)) return error.InvalidPackage;

    @memcpy(out[0..source.len], source);
    length.* = @intCast(source.len);

}

fn valid_id(id: []const u8) bool {

    if (id.len < 2 or id.len > 32) return false;

    for (id) |byte| {

        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-';

        if (!valid) return false;

    }

    return id[0] >= 'a' and id[0] <= 'z';

}

fn valid_text(text: []const u8) bool {

    for (text) |byte| {

        if (byte < 0x20 or byte >= 0x7f or byte == '\t' or byte == '\n' or byte == '\r') return false;

    }

    return true;

}

fn valid_hash(text: []const u8) bool {

    if (text.len != 64) return false;

    for (text) |byte| {

        if (!std.ascii.isHex(byte)) return false;

    }

    return true;

}

fn valid_https_url(url: []const u8) bool {

    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len;

}

const testing = std.testing;

test "rejects malformed executable images" {

    try testing.expectError(error.InvalidPackage, verify_elf("not an elf"));

}

test "decodes installed catalog records" {

    const line = "hello\t1.2.0\tHello\tExample app\tapps\tAccessories\t0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
    var items: [2]Installed = undefined;

    const count = decode_catalog(line, &items);

    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("hello", items[0].program());
    try testing.expectEqualStrings("1.2.0", items[0].release());

}
