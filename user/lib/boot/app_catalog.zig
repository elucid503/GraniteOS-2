// Runtime parser for the build-generated `app-catalog` bundle module. Marble seeds disk programs from the
// program table; the taskbar launcher menu reads the desktop table.

const std = @import("std");

pub const magic: u32 = 0x474e_4341;
pub const version: u32 = 1;

const header_size = 16;
const bundle_name_bytes = 24;
const program_description_bytes = 48;
const program_category_bytes = 16;
const program_entry_size = bundle_name_bytes + program_description_bytes + program_category_bytes;
const desktop_title_bytes = 32;
const desktop_description_bytes = 48;
const desktop_icon_bytes = 16;
const desktop_category_bytes = 16;
const desktop_entry_size = bundle_name_bytes + desktop_title_bytes + desktop_description_bytes + desktop_icon_bytes + desktop_category_bytes;

pub const Program = struct {

    name: []const u8,
    description: []const u8,
    category: []const u8,

};

pub const Desktop = struct {

    program: []const u8,
    title: []const u8,
    description: []const u8,
    icon: []const u8,
    category: []const u8,

};

pub const Catalog = struct {

    bytes: []const u8,
    program_count: usize,
    desktop_count: usize,
    programs_offset: usize,
    desktop_offset: usize,

    pub fn open(bytes: []const u8) error{ Invalid }!Catalog {

        if (bytes.len < header_size) return error.Invalid;
        if (read_u32(bytes, 0) != magic) return error.Invalid;
        if (read_u32(bytes, 4) != version) return error.Invalid;

        const program_count: usize = @intCast(read_u32(bytes, 8));
        const desktop_count: usize = @intCast(read_u32(bytes, 12));

        const programs_offset = header_size;
        const desktop_offset = programs_offset + program_count * program_entry_size;
        const end = desktop_offset + desktop_count * desktop_entry_size;

        if (end > bytes.len) return error.Invalid;

        return .{

            .bytes = bytes,
            .program_count = program_count,
            .desktop_count = desktop_count,
            .programs_offset = programs_offset,
            .desktop_offset = desktop_offset,

        };

    }

    pub fn program(self: *const Catalog, index: usize) ?Program {

        if (index >= self.program_count) return null;

        const entry = self.programs_offset + index * program_entry_size;

        return .{

            .name = fixed_name(self.bytes[entry .. entry + bundle_name_bytes]),
            .description = fixed_text(self.bytes[entry + bundle_name_bytes .. entry + bundle_name_bytes + program_description_bytes]),
            .category = fixed_text(self.bytes[entry + bundle_name_bytes + program_description_bytes .. entry + program_entry_size]),

        };

    }

    pub fn desktop(self: *const Catalog, index: usize) ?Desktop {

        if (index >= self.desktop_count) return null;

        const entry = self.desktop_offset + index * desktop_entry_size;
        const title_end = entry + bundle_name_bytes + desktop_title_bytes;
        const description_end = title_end + desktop_description_bytes;
        const icon_end = description_end + desktop_icon_bytes;

        return .{

            .program = fixed_name(self.bytes[entry .. entry + bundle_name_bytes]),
            .title = fixed_text(self.bytes[entry + bundle_name_bytes .. title_end]),
            .description = fixed_text(self.bytes[title_end..description_end]),
            .icon = fixed_text(self.bytes[description_end..icon_end]),
            .category = fixed_text(self.bytes[icon_end .. entry + desktop_entry_size]),

        };

    }

};

fn fixed_name(raw: []const u8) []const u8 {

    return raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];

}

fn fixed_text(raw: []const u8) []const u8 {

    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;

    return raw[0..end];

}

fn read_u32(bytes: []const u8, offset: usize) u32 {

    return std.mem.readInt(u32, bytes[offset..][0..4], .little);

}

const testing = std.testing;

test "parses catalog tables" {

    var bytes = [_]u8{0} ** 256;

    std.mem.writeInt(u32, bytes[0..4], magic, .little);
    std.mem.writeInt(u32, bytes[4..8], version, .little);
    std.mem.writeInt(u32, bytes[8..12], 1, .little);
    std.mem.writeInt(u32, bytes[12..16], 1, .little);

    @memcpy(bytes[16..20], "echo");
    @memcpy(bytes[40..46], "prints");
    @memcpy(bytes[88..94], "common");

    const desktop_base = header_size + program_entry_size;
    @memcpy(bytes[desktop_base .. desktop_base + 5], "files");
    @memcpy(bytes[desktop_base + 24 .. desktop_base + 29], "Files");
    @memcpy(bytes[desktop_base + 56 .. desktop_base + 61], "browse");
    @memcpy(bytes[desktop_base + 104 .. desktop_base + 110], "folder");

    const catalog = try Catalog.open(bytes[0 .. desktop_base + desktop_entry_size]);

    try testing.expectEqualStrings("echo", catalog.program(0).?.name);
    try testing.expectEqualStrings("files", catalog.desktop(0).?.program);
    try testing.expectEqualStrings("folder", catalog.desktop(0).?.icon);

}