// HTTP-semantic types — protocol-agnostic.
//
// Handlers never see frame types, stream IDs, or QPACK state.
// The HTTP/3 adapter layer translates between wire protocol and these types.

pub const MAX_HEADERS = 64;

pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    fields: [MAX_HEADERS]HeaderField = undefined,
    len: usize = 0,

    pub fn add(self: *Headers, name: []const u8, value: []const u8) void {
        self.fields[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.fields[0..self.len]) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    pub fn items(self: *const Headers) []const HeaderField {
        return self.fields[0..self.len];
    }
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: Headers,
    body: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    headers: Headers = .{},
    body: []const u8 = "",
};

/// Protocol-agnostic request handler.
/// Operates on pre-allocated buffers — no allocator in the signature.
pub const Handler = *const fn (req: *const Request, res: *Response) void;

/// Middleware function: calls next() to continue the chain.
pub const MiddlewareFn = *const fn (req: *const Request, res: *Response, next: Handler) void;

const std = @import("std");

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "Headers: add and get" {
    const std_ = @import("std");
    var h: Headers = .{};
    h.add("content-type", "application/json");
    h.add("x-request-id", "abc-123");

    try std_.testing.expectEqualStrings("application/json", h.get("content-type").?);
    try std_.testing.expectEqualStrings("abc-123", h.get("x-request-id").?);
    try std_.testing.expectEqual(@as(?[]const u8, null), h.get("authorization"));
}

test "Headers: items slice" {
    const std_ = @import("std");
    var h: Headers = .{};
    h.add("a", "1");
    h.add("b", "2");

    const s = h.items();
    try std_.testing.expectEqual(@as(usize, 2), s.len);
    try std_.testing.expectEqualStrings("a", s[0].name);
    try std_.testing.expectEqualStrings("2", s[1].value);
}

test "Response: default values" {
    const std_ = @import("std");
    const res: Response = .{};
    try std_.testing.expectEqual(@as(u16, 200), res.status);
    try std_.testing.expectEqualStrings("", res.body);
    try std_.testing.expectEqual(@as(usize, 0), res.headers.len);
}
