// QPACK decoder — RFC 9204, static table only (Phase 1).
//
// Accepts header blocks with any Required Insert Count and Base, but returns
// DynamicTableRequired if any field line references the dynamic table.
//
// Field line representations handled:
//   §4.5.2  Indexed Field Line          (T=1 static only)
//   §4.5.4  Literal with Name Reference (T=1 static only)
//   §4.5.6  Literal with Literal Name
//
// References to the dynamic table (T=0, post-base index, post-base name ref)
// return error.DynamicTableRequired.

const std = @import("std");
const static_table = @import("static_table.zig");
const int = @import("int.zig");
const huffman = @import("huffman.zig");
const string = @import("string.zig");
pub const Field = @import("types.zig").Field;

pub const DecodeError = error{
    /// Header block references the dynamic table, which is not implemented.
    DynamicTableRequired,
    /// Malformed header block (invalid index, bad encoding, etc.).
    InvalidInput,
    /// Input is truncated.
    Incomplete,
    /// Integer overflow in a length or index field.
    Overflow,
    /// Invalid Huffman code.
    InvalidCode,
    /// EOS symbol appeared in a header string value.
    EosInValue,
    /// Output slice too small.
    BufferTooSmall,
};

/// Decodes a QPACK header block from `buf` into `out_fields`.
///
/// `strings` is a scratch buffer for Huffman-decoded string data. The decoded
/// Field slices may reference either `buf` (literal strings) or `strings`
/// (Huffman strings). Both must remain live as long as the fields are used.
///
/// Returns the number of fields written to `out_fields`.
pub fn decode(
    buf: []const u8,
    out_fields: []Field,
    strings: []u8,
) DecodeError!usize {
    var pos: usize = 0;
    var str_pos: usize = 0;
    var field_count: usize = 0;

    // ---- Header block prefix (§4.3) ----------------------------------------
    // Required Insert Count (8-bit prefix integer).
    if (pos >= buf.len) return error.Incomplete;
    const ric = try int.decode(buf[pos..], 8);
    pos += ric.consumed;

    // S bit + Delta Base (S in bit7, base is 7-bit prefix integer).
    if (pos >= buf.len) return error.Incomplete;
    const base = try int.decode(buf[pos..], 7);
    pos += base.consumed;

    // RIC and Base are parsed to advance past the prefix. Static table indices
    // are absolute so their values don't affect decoding.

    // ---- Field lines --------------------------------------------------------
    while (pos < buf.len) {
        if (field_count >= out_fields.len) return error.BufferTooSmall;
        const byte = buf[pos];

        if ((byte & 0x80) != 0) {
            // §4.5.2 Indexed Field Line: 1 T [6-bit index]
            if ((byte & 0x40) == 0) return error.DynamicTableRequired; // T=0

            const idx = try int.decode(buf[pos..], 6);
            pos += idx.consumed;
            if (idx.value > 98) return error.InvalidInput;

            const entry = static_table.get(@intCast(idx.value)).?;
            out_fields[field_count] = .{ .name = entry.name, .value = entry.value };
            field_count += 1;
        } else if ((byte & 0x40) != 0) {
            // §4.5.4 Literal Field Line with Name Reference: 0 1 N T [4-bit index]
            if ((byte & 0x10) == 0) return error.DynamicTableRequired; // T=0

            const idx = try int.decode(buf[pos..], 4);
            pos += idx.consumed;
            if (idx.value > 98) return error.InvalidInput;

            const entry = static_table.get(@intCast(idx.value)).?;

            const val = try string.decode(buf[pos..], strings[str_pos..]);
            pos += val.consumed;
            if (val.huffman_decoded) str_pos += val.value.len;

            out_fields[field_count] = .{ .name = entry.name, .value = val.value };
            field_count += 1;
        } else if ((byte & 0x20) != 0) {
            // §4.5.6 Literal Field Line with Literal Name: 0 0 1 N H [3-bit name len]
            const name_is_huffman = (byte & 0x08) != 0;
            const name_len_int = try int.decode(buf[pos..], 3);
            pos += name_len_int.consumed;

            const name_len: usize = @intCast(name_len_int.value);
            if (pos + name_len > buf.len) return error.Incomplete;

            const name_raw = buf[pos .. pos + name_len];
            pos += name_len;

            const name: []const u8 = if (name_is_huffman) blk: {
                const n = try huffman.decode(name_raw, strings[str_pos..]);
                const s = strings[str_pos .. str_pos + n];
                str_pos += n;
                break :blk s;
            } else name_raw;

            const val = try string.decode(buf[pos..], strings[str_pos..]);
            pos += val.consumed;
            if (val.huffman_decoded) str_pos += val.value.len;

            out_fields[field_count] = .{ .name = name, .value = val.value };
            field_count += 1;
        } else if ((byte & 0x10) != 0) {
            // §4.5.3 Indexed Field Line with Post-Base Index: 0 0 0 1 [4-bit index]
            return error.DynamicTableRequired;
        } else {
            // §4.5.5 Literal Field Line with Post-Base Name Reference: 0 0 0 0 ...
            return error.DynamicTableRequired;
        }
    }

    return field_count;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "decode: indexed field line (static)" {
    // [0x00, 0x00, 0xd1] → :method GET (static index 17)
    const buf = [_]u8{ 0x00, 0x00, 0xd1 };
    var fields: [8]Field = undefined;
    var strings: [256]u8 = undefined;
    const n = try decode(&buf, &fields, &strings);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings(":method", fields[0].name);
    try std.testing.expectEqualStrings("GET", fields[0].value);
}

test "decode: indexed at index > 62 (multi-byte)" {
    // :status 500 = static index 71. Encoded as [0xff, 0x08] (63+8=71), T=1.
    const buf = [_]u8{ 0x00, 0x00, 0xff, 0x08 };
    var fields: [8]Field = undefined;
    var strings: [256]u8 = undefined;
    const n = try decode(&buf, &fields, &strings);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings(":status", fields[0].name);
    try std.testing.expectEqualStrings("500", fields[0].value);
}

test "decode: dynamic table reference returns error" {
    // T=0: Indexed Field Line with T=0 → DynamicTableRequired
    const buf = [_]u8{ 0x00, 0x00, 0x81 }; // 0x81 = 1 0 000001, T=0
    var fields: [8]Field = undefined;
    var strings: [256]u8 = undefined;
    try std.testing.expectError(
        error.DynamicTableRequired,
        decode(&buf, &fields, &strings),
    );
}

test "decode: empty header block" {
    const buf = [_]u8{ 0x00, 0x00 };
    var fields: [8]Field = undefined;
    var strings: [256]u8 = undefined;
    const n = try decode(&buf, &fields, &strings);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "decode: incomplete input" {
    const buf = [_]u8{0x00}; // only RIC byte, no Base byte
    var fields: [8]Field = undefined;
    var strings: [256]u8 = undefined;
    try std.testing.expectError(error.Incomplete, decode(&buf, &fields, &strings));
}

test "encode/decode round-trip: all three representation types" {
    const encoder = @import("encoder.zig");

    // Covers:
    //   :method GET    → §4.5.2 Indexed (exact static match)
    //   :scheme https  → §4.5.2 Indexed (exact static match)
    //   :path /hello   → §4.5.4 Literal with static name ref (:path idx 1)
    //   :authority example.com → §4.5.4 Literal with static name ref
    //   x-request-id 42 → §4.5.6 Literal with literal name
    const in_fields = [_]Field{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/hello" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = "x-request-id", .value = "42" },
    };

    var enc_buf: [512]u8 = undefined;
    const enc_n = try encoder.encode(&in_fields, &enc_buf);

    var out_fields: [16]Field = undefined;
    var strings: [512]u8 = undefined;
    const dec_n = try decode(enc_buf[0..enc_n], &out_fields, &strings);

    try std.testing.expectEqual(@as(usize, in_fields.len), dec_n);
    for (in_fields, out_fields[0..dec_n]) |expected, got| {
        try std.testing.expectEqualStrings(expected.name, got.name);
        try std.testing.expectEqualStrings(expected.value, got.value);
    }
}

test "round-trip: headers with values already in static table" {
    const encoder = @import("encoder.zig");
    // All of these have exact matches in the static table.
    const in_fields = [_]Field{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":status", .value = "200" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "content-encoding", .value = "gzip" },
    };

    var enc_buf: [256]u8 = undefined;
    const enc_n = try encoder.encode(&in_fields, &enc_buf);

    var out_fields: [16]Field = undefined;
    var strings: [256]u8 = undefined;
    const dec_n = try decode(enc_buf[0..enc_n], &out_fields, &strings);

    try std.testing.expectEqual(@as(usize, in_fields.len), dec_n);
    for (in_fields, out_fields[0..dec_n]) |expected, got| {
        try std.testing.expectEqualStrings(expected.name, got.name);
        try std.testing.expectEqualStrings(expected.value, got.value);
    }
}
