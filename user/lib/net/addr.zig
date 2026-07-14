// IPv4 address helpers and the Internet checksum

/// Parse a dotted-quad string ("10.0.2.15") into a packed u32. No hostnames, no IPv6 - the stack speaks IPv4 only.
pub fn parse_ipv4(text: []const u8) ?u32 {

    var value: u32 = 0;
    var octet: u32 = 0;
    var digits: u32 = 0;
    var octets: u32 = 0;

    for (text) |byte| {

        if (byte == '.') {

            if (digits == 0 or octets == 3) return null;

            value = (value << 8) | octet;
            octet = 0;
            digits = 0;
            octets += 1;

            continue;

        }

        if (byte < '0' or byte > '9') return null;

        octet = octet * 10 + (byte - '0');
        digits += 1;

        if (digits > 3 or octet > 255) return null;

    }

    if (digits == 0 or octets != 3) return null;

    return (value << 8) | octet;

}

/// Render a packed u32 address as a dotted quad into `out`, returning the written slice.
pub fn format_ipv4(addr: u32, out: []u8) []const u8 {

    var cursor: usize = 0;

    inline for (0..4) |index| {

        if (index != 0) {

            out[cursor] = '.';
            cursor += 1;

        }

        const octet: u8 = @truncate(addr >> @intCast(8 * (3 - index)));

        cursor += write_decimal(octet, out[cursor..]);

    }

    return out[0..cursor];

}

fn write_decimal(value: u8, out: []u8) usize {

    if (value >= 100) {

        out[0] = '0' + value / 100;
        out[1] = '0' + (value / 10) % 10;
        out[2] = '0' + value % 10;

        return 3;

    }

    if (value >= 10) {

        out[0] = '0' + value / 10;
        out[1] = '0' + value % 10;

        return 2;

    }

    out[0] = '0' + value;

    return 1;

}

/// The Internet checksum (RFC 1071): fold a run of bytes into one's-complement 16-bit sum, then invert. The `seed` argument allows building a checksum across several discontiguous spans.
pub fn checksum(seed: u32, bytes: []const u8) u16 {

    var sum: u32 = seed;
    var index: usize = 0;

    while (index + 1 < bytes.len) : (index += 2) {

        sum += (@as(u32, bytes[index]) << 8) | bytes[index + 1];

    }

    if (index < bytes.len) sum += @as(u32, bytes[index]) << 8;

    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);

    return @truncate(~sum);

}

/// Fold a run of bytes into a running sum without finishing it. Good for building a checksum across several discontiguous spans.
pub fn checksum_seed(seed: u32, bytes: []const u8) u32 {

    var sum: u32 = seed;
    var index: usize = 0;

    while (index + 1 < bytes.len) : (index += 2) {

        sum += (@as(u32, bytes[index]) << 8) | bytes[index + 1];

    }

    if (index < bytes.len) sum += @as(u32, bytes[index]) << 8;

    return sum;

}

fn finish_checksum(sum_in: u32) u16 {

    var sum = sum_in;

    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);

    return @truncate(~sum);

}

pub const finish = finish_checksum;

const testing = @import("std").testing;

test "parses and formats a dotted quad" {

    try testing.expectEqual(@as(?u32, 0x0a00_020f), parse_ipv4("10.0.2.15"));
    try testing.expectEqual(@as(?u32, null), parse_ipv4("10.0.2"));
    try testing.expectEqual(@as(?u32, null), parse_ipv4("10.0.2.256"));

    var buffer: [16]u8 = undefined;

    try testing.expectEqualStrings("10.0.2.15", format_ipv4(0x0a00_020f, &buffer));
    try testing.expectEqualStrings("0.0.0.0", format_ipv4(0, &buffer));
    try testing.expectEqualStrings("255.255.255.255", format_ipv4(0xffff_ffff, &buffer));

}

test "checksum of a zero buffer is all ones" {

    const zeros = [_]u8{0} ** 20;

    try testing.expectEqual(@as(u16, 0xffff), checksum(0, &zeros));

}
