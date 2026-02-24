// QPACK encoder — RFC 9204, static table only (Phase 1).
//
// Produces header blocks with Required Insert Count = 0 (no dynamic table).
// Field line representations used:
//   §4.5.2  Indexed Field Line          — exact name+value in static table
//   §4.5.4  Literal with Name Reference — name in static table, literal value
//   §4.5.6  Literal with Literal Name   — neither name nor value in static table

const std = @import("std");
const static_table = @import("static_table.zig");
const int = @import("int.zig");
const huffman = @import("huffman.zig");
const string = @import("string.zig");
pub const Field = @import("types.zig").Field;

/// Encodes `fields` into a QPACK header block in `buf`.
/// Returns the number of bytes written.
pub fn encode(fields: []const Field, buf: []u8) error{BufferTooSmall}!usize {
    if (buf.len < 2) return error.BufferTooSmall;

    // Header block prefix: Required Insert Count = 0, S=0, Base = 0.
    buf[0] = 0x00;
    buf[1] = 0x00;
    var pos: usize = 2;

    for (fields) |field| {
        pos += try encodeField(field, buf[pos..]);
    }

    return pos;
}

fn encodeField(field: Field, buf: []u8) error{BufferTooSmall}!usize {
    // 1. Exact name+value match in static table → §4.5.2 Indexed Field Line.
    if (static_table.findExact(field.name, field.value)) |idx| {
        // Wire format: 1 T [6-bit index]  (T=1 for static)
        const written = try int.encode(buf, 6, idx);
        buf[0] |= 0b1100_0000; // bit7=1 (Indexed), bit6=T=1 (static)
        return written;
    }

    // 2. Name-only match in static table → §4.5.4 Literal with Name Reference.
    if (static_table.findName(field.name)) |idx| {
        // Wire format: 0 1 N T [4-bit index]  (N=0, T=1)
        var pos: usize = 0;
        const written = try int.encode(buf, 4, idx);
        buf[0] |= 0b0101_0000; // 01 N=0 T=1
        pos += written;
        pos += try string.encode(field.value, buf[pos..]);
        return pos;
    }

    // 3. No static table match → §4.5.6 Literal with Literal Name.
    return encodeLiteralName(field, buf);
}

fn encodeLiteralName(field: Field, buf: []u8) error{BufferTooSmall}!usize {
    var pos: usize = 0;

    // Decide whether to Huffman-encode the name.
    const name_huff_len = huffman.encodedLen(field.name);
    const use_name_huff = name_huff_len < field.name.len;
    const name_data_len: u64 = if (use_name_huff) name_huff_len else field.name.len;

    // Wire format for first byte: 0 0 1 N H [3-bit name-length prefix]
    //   bits 7-5 = 001 (field type)
    //   bit  4   = N = 0 (allow indexing)
    //   bit  3   = H (Huffman flag for name)
    //   bits 2-0 = 3-bit prefix for name length
    const name_hdr_written = try int.encode(buf[pos..], 3, name_data_len);
    buf[pos] |= 0b0010_0000; // set type bits 001, N=0
    if (use_name_huff) buf[pos] |= 0b0000_1000; // set H=1
    pos += name_hdr_written;

    // Write name bytes.
    const name_end = pos + @as(usize, @intCast(name_data_len));
    if (buf.len < name_end) return error.BufferTooSmall;
    if (use_name_huff) {
        _ = try huffman.encode(field.name, buf[pos..name_end]);
    } else {
        @memcpy(buf[pos..name_end], field.name);
    }
    pos = name_end;

    // Write value (standard string literal: H in bit7, 7-bit prefix).
    pos += try string.encode(field.value, buf[pos..]);

    return pos;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "encode: indexed field line (exact static match)" {
    // :method GET is static index 17.
    // Expected: [0x00, 0x00, 0xd1]
    //   0x00 = RIC=0,  0x00 = Base=0
    //   0xd1 = 0b11010001 = Indexed(T=1) | idx=17
    var buf: [32]u8 = undefined;
    const n = try encode(&.{.{ .name = ":method", .value = "GET" }}, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xd1), buf[2]);
}

test "encode: indexed at index > 62 (multi-byte integer)" {
    // :status 500 is static index 71.
    // 71 >= 63 → needs multi-byte: [0xff, 0x08]  (63 + 8 = 71)
    // With T=1 bits: first byte = 0xff (0xc0 | 0x3f), second = 0x08
    var buf: [32]u8 = undefined;
    const n = try encode(&.{.{ .name = ":status", .value = "500" }}, &buf);
    try std.testing.expectEqual(@as(usize, 4), n); // 2 prefix + 2 index bytes
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[2]); // Indexed T=1, prefix all-1s
    try std.testing.expectEqual(@as(u8, 0x08), buf[3]); // 71 - 63 = 8
}

test "encode: literal with static name reference" {
    // :path /hello: name ':path' is at static index 1, value '/hello' is not in table.
    // Wire: [0x00, 0x00, 0x51, <value string>]
    //   0x51 = 0b01010001 = Literal NameRef (01) N=0 T=1 idx=1
    var buf: [64]u8 = undefined;
    const n = try encode(&.{.{ .name = ":path", .value = "/hello" }}, &buf);
    try std.testing.expect(n > 3);
    try std.testing.expectEqual(@as(u8, 0x51), buf[2]); // NameRef, T=1, idx=1
}

test "encode: literal with literal name" {
    // x-custom-header: foo → not in static table at all.
    var buf: [128]u8 = undefined;
    const n = try encode(&.{.{ .name = "x-custom-header", .value = "foo" }}, &buf);
    try std.testing.expect(n > 2);
    // First byte of field: bits 7-5 = 001 (literal name type)
    try std.testing.expectEqual(@as(u8, 0b001), (buf[2] >> 5) & 0b111);
}

test "encode: multiple fields" {
    const fields = [_]Field{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.com" },
    };
    var buf: [128]u8 = undefined;
    const n = try encode(&fields, &buf);
    try std.testing.expect(n > 4);
    // First 2 bytes are the required insert count / base prefix.
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
}

test "encode: buffer too small" {
    var buf: [1]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        encode(&.{.{ .name = ":method", .value = "GET" }}, &buf),
    );
}
