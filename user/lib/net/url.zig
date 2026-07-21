// A tiny URL parser: scheme://host[:port][/path].

const std = @import("std");

pub const Url = struct {

    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,

};

pub fn is_tls(scheme: []const u8) bool {

    return std.mem.eql(u8, scheme, "https");

}

pub fn parse(text: []const u8) ?Url {

    const sep = "://";
    const scheme_end = std.mem.indexOf(u8, text, sep) orelse return null;
    const scheme = text[0..scheme_end];

    if (scheme.len == 0) return null;

    const default_port: u16 = if (std.mem.eql(u8, scheme, "http"))
        80
    else if (std.mem.eql(u8, scheme, "https"))
        443
    else
        return null;

    const rest = text[scheme_end + sep.len ..];

    if (rest.len == 0) return null;

    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..path_start];
    const path = if (path_start == rest.len) "/" else rest[path_start..];

    if (authority.len == 0) return null;

    var host = authority;
    var port: u16 = default_port;

    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {

        host = authority[0..colon];

        const port_text = authority[colon + 1 ..];

        if (host.len == 0 or port_text.len == 0) return null;

        port = std.fmt.parseInt(u16, port_text, 10) catch return null;

    }

    return .{ .scheme = scheme, .host = host, .port = port, .path = path };

}

const testing = std.testing;

test "parses host, default port and path" {

    const url = parse("http://example.com/") orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("http", url.scheme);
    try testing.expectEqualStrings("example.com", url.host);
    try testing.expectEqual(@as(u16, 80), url.port);
    try testing.expectEqualStrings("/", url.path);

}

test "parses https default port" {

    const url = parse("https://example.com/a") orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("https", url.scheme);
    try testing.expectEqual(@as(u16, 443), url.port);
    try testing.expectEqualStrings("/a", url.path);
    try testing.expect(is_tls(url.scheme));

}

test "parses explicit port and path" {

    const url = parse("http://example.com:8080/a/b") orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("example.com", url.host);
    try testing.expectEqual(@as(u16, 8080), url.port);
    try testing.expectEqualStrings("/a/b", url.path);

}

test "defaults path to / when missing" {

    const url = parse("http://example.com") orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("/", url.path);

}

test "rejects malformed input" {

    try testing.expectEqual(@as(?Url, null), parse("example.com/path"));
    try testing.expectEqual(@as(?Url, null), parse("http://"));
    try testing.expectEqual(@as(?Url, null), parse("http://:80/"));
    try testing.expectEqual(@as(?Url, null), parse("ftp://example.com/"));
    try testing.expectEqual(@as(?Url, null), parse("http://example.com:notaport/"));

}
