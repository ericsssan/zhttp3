# zhttp3 — Design Document

> HTTP/3 framing, QPACK, and an opinionated server layer built on zquic.

---

## 1. Scope

zhttp3 implements the application layer of the HTTP/3 stack:

```
┌──────────────────────────────────────────────────────┐
│  src/server/   Server layer                          │
│                Handler(Request, Response)            │  ← protocol-agnostic
│                comptime router, middleware           │
├──────────────────────────────────────────────────────┤
│  src/http3/    HTTP/3 adapter          RFC 9114      │  ← translates between
│  src/qpack/    QPACK                   RFC 9204      │    wire and HTTP types
├──────────────────────────────────────────────────────┤
│  zquic         QUIC transport          RFC 9000      │  ← separate library
│                QUIC-TLS                RFC 9001      │
│                Loss detection + CC     RFC 9002      │
└──────────────────────────────────────────────────────┘
```

| Layer    | RFC      | Responsibility                              |
|----------|----------|---------------------------------------------|
| QPACK    | RFC 9204 | Header compression and decompression        |
| HTTP/3   | RFC 9114 | Request/response framing over QUIC streams  |
| Server   | —        | Router, handlers, middleware                |

zquic handles everything below: QUIC transport, TLS 1.3, loss recovery,
congestion control, flow control, connection management.

---

## 2. Layer Design

### QPACK (RFC 9204)

QPACK compresses HTTP headers using a static table (99 entries defined by
the spec) and an optional dynamic table updated via two dedicated QUIC
unidirectional streams (encoder stream, decoder stream).

```
Static table:   99 pre-defined header field entries — no streams needed
Dynamic table:  encoder sends updates on encoder stream
                decoder acknowledges on decoder stream
                blocked streams: requests waiting for dynamic table updates
```

Design decisions:
- Static table lookup: comptime perfect hash — zero runtime overhead
- Dynamic table: bounded size, configurable at connection setup
- Blocked streams: implement the blocking/unblocking protocol per RFC 9204
- Zero allocation for static-only requests (most requests in practice)

### HTTP/3 Framing (RFC 9114)

HTTP/3 maps HTTP semantics onto QUIC streams:

```
Client request:   opens a bidirectional QUIC stream
                  sends HEADERS frame (QPACK-compressed)
                  sends DATA frames (request body, if any)

Server response:  sends HEADERS frame on the same stream
                  sends DATA frames (response body)
                  closes stream

Control streams:  two unidirectional streams (client→server, server→client)
                  carry SETTINGS frame and other control frames

QPACK streams:    two unidirectional streams per side
                  encoder stream, decoder stream
```

Frame types handled:
```
DATA        (0x0)  — request/response body
HEADERS     (0x1)  — QPACK-compressed header block
CANCEL_PUSH (0x3)  — cancel a server push
SETTINGS    (0x4)  — connection-level settings
PUSH_PROMISE(0x5)  — server push
GOAWAY      (0x7)  — graceful shutdown signal
MAX_PUSH_ID (0xD)  — flow control for server push
```

### Server Layer

The server layer is protocol-agnostic. Handlers have no knowledge of QUIC
streams, HTTP/3 frames, or QPACK. The HTTP/3 layer translates between the
wire protocol and HTTP-semantic types — handlers only ever see `Request` and
`Response`.

```
src/server/    Handler(Request, Response)    ← protocol-agnostic
                            ▲
src/http3/     QUIC streams → Request        ← adapter
               Response → QUIC streams
                            ▲
zquic          raw QUIC streams              ← transport
```

The HTTP/3 layer is responsible for:
- Parsing HEADERS frames (QPACK-decoded) → `Request`
- Reading DATA frames → request body
- Encoding `Response` headers → HEADERS frame (QPACK-encoded)
- Writing response body → DATA frames
- Managing stream lifecycle

The server layer never touches frame types, stream IDs, or QPACK state.

#### Request and Response types

```zig
pub const Request = struct {
    method:  []const u8,
    path:    []const u8,
    query:   []const u8,
    headers: Headers,
    body:    []const u8,
};

pub const Response = struct {
    status:  u16,
    headers: Headers,
    body:    []const u8,
};
```

No protocol details leak into these types. Handlers are independently
testable — pass a `Request`, assert on the `Response`, no network stack needed.

#### Comptime router

Routes are registered at compile time. The router is a perfect hash table
computed at build time — zero runtime dispatch overhead, no heap allocation,
no string comparison in the hot path.

```zig
const router = comptime Router.init(.{
    .{ "GET",  "/v1/get",    kvGet  },
    .{ "POST", "/v1/set",    kvSet  },
    .{ "GET",  "/healthz",   health },
});
```

Unknown routes return 404 with no allocation. The router is a compile-time
constant — not a data structure built at startup.

#### Handler interface

```zig
pub const Handler = *const fn (req: *const Request, res: *Response) void;
```

Handlers operate on pre-allocated buffers provided by the server. No
allocator in the handler signature — no allocation in the hot path.

#### Middleware chain

Middleware wraps handlers. Resolved at compile time — no runtime linked list,
no vtable, no heap allocation.

```zig
const chain = comptime Middleware.chain(.{
    logMiddleware,
    authMiddleware,
    router.handler(),
});
```

---

## 3. Implementation Roadmap

### Phase 1: QPACK
- Static table lookup (comptime perfect hash)
- Dynamic table (encoder/decoder streams)
- Blocked stream handling
- **Milestone**: QPACK encode/decode passes RFC 9204 test vectors

### Phase 2: HTTP/3 framing
- Frame parsing and serialisation (DATA, HEADERS, SETTINGS, GOAWAY)
- Control stream setup
- Request/response lifecycle over QUIC streams
- **Milestone**: HTTP/3 response to `curl --http3`

### Phase 3: Server layer
- Comptime router
- Handler interface
- Middleware chain
- In-memory KV handler (benchmark endpoint)
- **Milestone**: loopback benchmark, compare vs Node.js / Bun / Go fasthttp

### Phase 4: Server push + GOAWAY
- Server push (PUSH_PROMISE frames)
- Graceful shutdown via GOAWAY
- **Milestone**: clean shutdown under load, no dropped requests
