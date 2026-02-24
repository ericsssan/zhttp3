# zhttp3 — Design Document

> HTTP/3 framing, QPACK, and an opinionated server layer built on zquic.

---

## 1. Scope

zhttp3 implements the application layer of the HTTP/3 stack:

```
┌──────────────────────────────────────────────────────┐
│  src/server/   Server layer                          │
│                Handler(Request, Response)            │  ← protocol-agnostic
│                comptime router, middleware, C API    │
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
| Server   | —        | Router, handlers, middleware, C API         |

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
PUSH_PROMISE(0x5)  — server push (phase 2)
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

## 3. Language Compatibility

The transport performance comes from zquic. zhttp3 adds the handler layer,
which can be written in any language at three levels.

### Level 1: C API

zhttp3 exposes a stable C API via `include/zhttp3.h`. Any language with C
FFI gets the full stack — QUIC transport + HTTP/3 framing + routing.

```c
ZHttp3Server* zhttp3_server_new(const ZHttp3Config* config);
void zhttp3_server_route(ZHttp3Server*, const char* method,
                         const char* path, HandlerFn handler);
int  zhttp3_server_listen(ZHttp3Server*, const char* addr, uint16_t port);
void zhttp3_server_free(ZHttp3Server*);
```

| Language | Method              | Handler speed     |
|----------|---------------------|-------------------|
| C / C++  | #include + link     | full              |
| Rust     | bindgen             | full              |
| Go       | cgo                 | near-full         |
| Python   | ctypes / cffi       | Python-speed      |
| Node.js  | napi                | JS-speed          |

Transport runs at full speed regardless. The handler runs at the speed of
the chosen language.

### Level 2: Handler ABI (.so plugin)

A stable binary ABI lets handlers be compiled to `.so` and loaded at runtime.
Any language that compiles to a shared library can implement it.

```c
// zhttp3.h — stable ABI contract
typedef struct {
    const char*    method;     size_t method_len;
    const char*    path;       size_t path_len;
    const char*    query;      size_t query_len;
    const uint8_t* body;       size_t body_len;
    const char**   header_names;
    const char**   header_values;
    size_t         header_count;
} ZHttp3Request;

typedef struct {
    uint16_t       status;
    const uint8_t* body;       size_t body_len;
    const char**   header_names;
    const char**   header_values;
    size_t         header_count;
} ZHttp3Response;

typedef void (*HandlerFn)(const ZHttp3Request*, ZHttp3Response*, void* ctx);
```

| Language | Target              | Performance  |
|----------|---------------------|--------------|
| Zig      | .so native          | full         |
| C / C++  | .so native          | full         |
| Rust     | .so cdylib          | full         |
| Go       | .so cgo             | near-full    |
| Swift    | .so native          | near-full    |
| Java     | .so GraalVM native  | good         |

Hot reload: swap `.so` without restarting. Different routes can dispatch to
handlers compiled from different languages simultaneously.

### Level 3: WebAssembly

Handlers compiled to `.wasm` run inside a wasmtime sandbox embedded in
zhttp3. Any language that compiles to WASM is supported.

```
Handler (any language) → compile → handler.wasm → zhttp3 (wasmtime) → ~80–90% native
```

- Sandboxed: handler crash cannot kill the server
- Hot reload: swap `.wasm` at runtime without restart
- Same model as Cloudflare Workers, Fastly Compute, AWS Lambda@Edge
- Cost: ~10–20% overhead vs native, ~5MB binary size increase (wasmtime)

### Migration path

```
Step 1 — drop in zhttp3, keep existing handler language
Step 2 — rewrite hot handlers (top 20% by traffic) in Zig/C/Rust
Step 3 — full Zig (optional, for maximum handler performance)
```

Steps 1 and 2 are sufficient for most production workloads.

---

## 4. Dependency Management

### Zig projects

`build.zig.zon`:
```zig
.dependencies = .{
    .zhttp3 = .{
        .url = "https://github.com/ericsssan/zhttp3/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

`build.zig`:
```zig
// Full server (most users)
exe.root_module.addImport("zhttp3", b.dependency("zhttp3", .{}).module("server"));

// HTTP/3 framing only (custom server logic)
exe.root_module.addImport("http3", b.dependency("zhttp3", .{}).module("http3"));
```

zhttp3 pulls in zquic transitively. No other dependencies.

### C/C++ projects

```
Build produces: libzhttp3.a (static), libzhttp3.so (dynamic)
Usage:          #include "zhttp3.h" + link -lzhttp3 -lzquic
```

---

## 5. Implementation Roadmap

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

### Phase 4: Language integrations
- zhttp3.h C header
- Handler ABI stabilised
- C, Rust, Go example handlers
- **Milestone**: Go handler running on zhttp3

### Phase 5: WebAssembly
- wasmtime embedding
- WASM handler loading and execution
- Hot reload
- **Milestone**: Rust handler compiled to .wasm running on zhttp3

### Phase 6: Server push + GOAWAY
- Server push (PUSH_PROMISE frames)
- Graceful shutdown via GOAWAY
- **Milestone**: clean shutdown under load, no dropped requests
