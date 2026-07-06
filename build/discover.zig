// Build-time discovery for every user-space ELF: walks the tree, applies bundle-name overrides, and extracts
// optional `app_meta` / `program_meta` blocks from source for the generated catalog.

const std = @import("std");

pub const Kind = enum {

    init,
    shell,
    driver,
    server,
    program,
    desktop,
    chrome,
    asset,

};

pub const Module = struct {

    bundle_name: []const u8,
    source: []const u8,
    elf_name: []const u8,
    kind: Kind,

    title: []const u8,
    description: []const u8,
    icon: []const u8,
    category: []const u8,

};

const Meta = struct {

    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    category: ?[]const u8 = null,

};

const bundle_overrides = std.StaticStringMap([]const u8).initComptime(.{

    .{ "servers/display", "compositor" },
    .{ "programs/gui/status", "status-gui" },

});

const chrome_gui = std.StaticStringMap(void).initComptime(.{

    .{ "welcome", {} },
    .{ "taskbar", {} },

});

const default_descriptions = std.StaticStringMap([]const u8).initComptime(.{

    .{ "echo", "Print arguments to stdout" },
    .{ "cat", "Copy stdin to stdout" },
    .{ "help", "List available programs" },
    .{ "about", "About GraniteOS" },
    .{ "hello", "Greeting from user space" },
    .{ "clear", "Clear the terminal screen" },
    .{ "wc", "Count lines and bytes from stdin" },
    .{ "status", "Show scheduler, disk, process, or CPU status" },
    .{ "stress", "Grind worker threads across all cores" },
    .{ "location", "Print the current directory" },
    .{ "ls", "List a directory" },
    .{ "view", "View a file (pager when interactive)" },
    .{ "write", "Edit or write a file" },
    .{ "create", "Create an empty file" },
    .{ "mkdir", "Create a directory" },
    .{ "delete", "Remove a file or empty directory" },
    .{ "rename", "Move a file or directory" },
    .{ "perms", "Set file write permission" },

});

pub const catalog_magic: u32 = 0x474e_4341;
pub const catalog_version: u32 = 1;

const catalog_header_size = 16;
const program_entry_size = 88;
const desktop_entry_size = 120;
const bundle_name_bytes = 24;
const program_description_bytes = 48;
const program_category_bytes = 16;
const desktop_title_bytes = 32;
const desktop_description_bytes = 48;
const desktop_icon_bytes = 16;

pub fn scan(allocator: std.mem.Allocator) ![]Module {

    var list: std.ArrayList(Module) = .empty;

    try append_fixed(&list, allocator, "user/flint/main.zig", .init);
    try append_fixed(&list, allocator, "user/marble/main.zig", .shell);

    try walk_dir(&list, allocator, "user/drivers", .driver, true);
    try walk_dir(&list, allocator, "user/servers", .server, true);
    try walk_programs(&list, allocator, "user/programs/common", .program, "common");
    try walk_programs(&list, allocator, "user/programs/fs", .program, "filesystem");
    try walk_programs(&list, allocator, "user/programs/location", .program, "location");
    try walk_gui(&list, allocator);

    return try list.toOwnedSlice(allocator);

}

pub fn generate_catalog_bytes(allocator: std.mem.Allocator, modules: []const Module) ![]u8 {

    var program_count: usize = 0;
    var desktop_count: usize = 0;

    for (modules) |module| {

        switch (module.kind) {

            .program => program_count += 1,
            .desktop => desktop_count += 1,
            else => {},

        }

    }

    const size = catalog_header_size + program_count * program_entry_size + desktop_count * desktop_entry_size;
    const output = try allocator.alloc(u8, size);

    @memset(output, 0);

    std.mem.writeInt(u32, output[0..4], catalog_magic, .little);
    std.mem.writeInt(u32, output[4..8], catalog_version, .little);
    std.mem.writeInt(u32, output[8..12], @intCast(program_count), .little);
    std.mem.writeInt(u32, output[12..16], @intCast(desktop_count), .little);

    var cursor: usize = catalog_header_size;

    for (modules) |module| {

        if (module.kind != .program) continue;

        write_program_entry(output[cursor .. cursor + program_entry_size], module);
        cursor += program_entry_size;

    }

    for (modules) |module| {

        if (module.kind != .desktop) continue;

        write_desktop_entry(output[cursor .. cursor + desktop_entry_size], module);
        cursor += desktop_entry_size;

    }

    return output;

}

fn append_fixed(list: *std.ArrayList(Module), allocator: std.mem.Allocator, rel: []const u8, kind: Kind) !void {

    const key = rel_key(rel);
    const bundle_name = bundle_name_for(key, kind);
    const meta = try read_meta(allocator, rel);

    try list.append(allocator, try make_module(allocator, rel, bundle_name, kind, meta, default_category(kind)));

}

fn walk_dir(list: *std.ArrayList(Module), allocator: std.mem.Allocator, rel: []const u8, kind: Kind, require_main: bool) !void {

    var dir = std.fs.cwd().openDir(rel, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();

    while (try iterator.next()) |entry| {

        if (entry.kind != .directory) continue;

        const child_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
        const source = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{child_rel});

        _ = require_main;

        std.fs.cwd().access(source, .{}) catch continue;

        const bundle_name = bundle_name_for(child_rel, kind);
        const meta = try read_meta(allocator, source);

        try list.append(allocator, try make_module(allocator, source, bundle_name, kind, meta, default_category(kind)));

    }

}

fn walk_programs(list: *std.ArrayList(Module), allocator: std.mem.Allocator, rel: []const u8, kind: Kind, category: []const u8) !void {

    var dir = std.fs.cwd().openDir(rel, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();

    while (try iterator.next()) |entry| {

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const child_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, std.fs.path.stem(entry.name) });
        const source = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
        const bundle_name = bundle_name_for(child_rel, kind);
        const meta = try read_meta(allocator, source);

        try list.append(allocator, try make_module(allocator, source, bundle_name, kind, meta, category));

    }

}

fn walk_gui(list: *std.ArrayList(Module), allocator: std.mem.Allocator) !void {

    const rel = "user/programs/gui";
    var dir = std.fs.cwd().openDir(rel, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();

    while (try iterator.next()) |entry| {

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const stem = std.fs.path.stem(entry.name);
        const child_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, stem });
        const source = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
        const bundle_name = bundle_name_for(child_rel, .desktop);
        const kind: Kind = if (chrome_gui.has(stem)) .chrome else .desktop;
        const meta = try read_meta(allocator, source);

        try list.append(allocator, try make_module(allocator, source, bundle_name, kind, meta, "desktop"));

    }

}

fn make_module(allocator: std.mem.Allocator, source: []const u8, bundle_name: []const u8, kind: Kind, meta: Meta, category: []const u8) !Module {

    const title = meta.title orelse try title_from_name(allocator, bundle_name);
    const description = meta.description orelse default_descriptions.get(bundle_name) orelse "";
    const icon = meta.icon orelse "apps";
    const resolved_category = meta.category orelse category;
    const elf_name = try std.fmt.allocPrint(allocator, "granite-{s}.elf", .{bundle_name});

    return .{

        .bundle_name = try allocator.dupe(u8, bundle_name),
        .source = try allocator.dupe(u8, source),
        .elf_name = try allocator.dupe(u8, elf_name),
        .kind = kind,

        .title = try allocator.dupe(u8, title),
        .description = try allocator.dupe(u8, description),
        .icon = try allocator.dupe(u8, icon),
        .category = try allocator.dupe(u8, resolved_category),

    };

}

fn bundle_name_for(key: []const u8, kind: Kind) []const u8 {

    const normalized = normalize_key(key);

    if (bundle_overrides.get(normalized)) |name| return name;

    const base = std.fs.path.basename(normalized);

    if (kind == .init) return "flint";
    if (kind == .shell) return "marble";

    return base;

}

fn default_category(kind: Kind) []const u8 {

    return switch (kind) {

        .driver => "driver",
        .server => "server",
        .desktop, .chrome => "desktop",
        else => "common",

    };

}

fn normalize_key(key: []const u8) []const u8 {

    if (std.mem.startsWith(u8, key, "user/")) return key[5..];

    return key;

}

fn rel_key(rel: []const u8) []const u8 {

    var trimmed = rel;

    if (std.mem.endsWith(u8, trimmed, "/main.zig")) {

        trimmed = trimmed[0 .. trimmed.len - "/main.zig".len];

    } else if (std.mem.endsWith(u8, trimmed, ".zig")) {

        trimmed = trimmed[0 .. trimmed.len - ".zig".len];

    }

    return trimmed;

}

fn title_from_name(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {

    var buffer = try allocator.alloc(u8, name.len);
    var out: usize = 0;
    var upper = true;

    for (name) |byte| {

        if (byte == '-') {

            if (out < buffer.len) buffer[out] = ' ';
            out += 1;
            upper = true;
            continue;

        }

        if (out < buffer.len) {

            buffer[out] = if (upper and byte >= 'a' and byte <= 'z') byte - 32 else byte;
            out += 1;

        }

        upper = false;

    }

    return buffer[0..out];

}

fn read_meta(allocator: std.mem.Allocator, path: []const u8) !Meta {

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024) catch return .{};
    defer allocator.free(bytes);

    var meta = Meta{};

    if (parse_meta_block(bytes, "app_meta")) |parsed| {

        meta = parsed;

    } else if (parse_meta_block(bytes, "program_meta")) |parsed| {

        meta = parsed;

    }

    if (meta.title) |title| meta.title = try allocator.dupe(u8, title);
    if (meta.description) |text| meta.description = try allocator.dupe(u8, text);
    if (meta.icon) |icon| meta.icon = try allocator.dupe(u8, icon);
    if (meta.category) |category| meta.category = try allocator.dupe(u8, category);

    return meta;

}

fn parse_meta_block(bytes: []const u8, field: []const u8) ?Meta {

    var marker_buffer: [48]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "pub const {s} = .{{", .{field}) catch return null;
    const start = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const end = std.mem.indexOf(u8, bytes[start..], "};") orelse return null;
    const block = bytes[start .. start + end];

    return .{

        .title = read_meta_string(block, "title"),
        .description = read_meta_string(block, "description"),
        .icon = read_meta_string(block, "icon"),
        .category = read_meta_string(block, "category"),

    };

}

fn read_meta_string(block: []const u8, field: []const u8) ?[]const u8 {

    var needle_buffer: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, ".{s} = \"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, block, needle) orelse return null;
    const quoted = block[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, quoted, '"') orelse return null;

    return quoted[0..end];

}

fn write_program_entry(out: []u8, module: Module) void {

    write_fixed_name(out[0..bundle_name_bytes], module.bundle_name);
    write_fixed_text(out[bundle_name_bytes .. bundle_name_bytes + program_description_bytes], module.description);
    write_fixed_text(out[bundle_name_bytes + program_description_bytes .. bundle_name_bytes + program_description_bytes + program_category_bytes], module.category);

}

fn write_desktop_entry(out: []u8, module: Module) void {

    write_fixed_name(out[0..bundle_name_bytes], module.bundle_name);
    write_fixed_text(out[bundle_name_bytes .. bundle_name_bytes + desktop_title_bytes], module.title);
    write_fixed_text(out[bundle_name_bytes + desktop_title_bytes .. bundle_name_bytes + desktop_title_bytes + desktop_description_bytes], module.description);
    write_fixed_text(out[bundle_name_bytes + desktop_title_bytes + desktop_description_bytes .. bundle_name_bytes + desktop_title_bytes + desktop_description_bytes + desktop_icon_bytes], module.icon);

}

fn write_fixed_name(out: []u8, name: []const u8) void {

    @memset(out, 0);
    @memcpy(out[0..@min(name.len, out.len)], name[0..@min(name.len, out.len)]);

}

fn write_fixed_text(out: []u8, text: []const u8) void {

    @memset(out, 0);
    @memcpy(out[0..@min(text.len, out.len)], text[0..@min(text.len, out.len)]);

}