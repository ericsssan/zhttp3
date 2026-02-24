# zhttp3

HTTP/3 framing, QPACK header compression, and an opinionated server layer,
built on [zquic](https://github.com/ericsssan/zquic).

> **Status: pre-release / active development.** QPACK Phase 1 is in progress.
> Not ready for production use.

---

## Overview

zhttp3 implements the application layer of the HTTP/3 stack:

```
┌──────────────────────────────────────────────────────┐
│  src/server/   Handler(Request, Response)            │  ← protocol-agnostic
│                comptime router, middleware, C API    │
├──────────────────────────────────────────────────────┤
│  src/http3/    HTTP/3 framing          RFC 9114      │  ← translates between
│  src/qpack/    QPACK                   RFC 9204      │    wire and HTTP types
├──────────────────────────────────────────────────────┤
│  zquic         QUIC transport          RFC 9000      │  ← separate library
└──────────────────────────────────────────────────────┘
```

Handlers are protocol-agnostic — they only see `Request` and `Response`.
No frame types, stream IDs, or QPACK state ever reaches handler code.

---

## Goals

- RFC-correct QPACK (RFC 9204) and HTTP/3 (RFC 9114) implementation in pure Zig
- Zero allocation in the hot path (pre-allocated buffers throughout)
- Comptime router with perfect hash — no runtime dispatch
- Pluggable handler ABI: Zig native, C/C++/Rust via `.so`, or WASM via wasmtime
- Designed for modern hardware (AES-NI, io_uring) via the underlying zquic transport

---

## Usage

### Zig

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
// Full server
exe.root_module.addImport("zhttp3", b.dependency("zhttp3", .{}).module("server"));

// HTTP/3 framing + QPACK only
exe.root_module.addImport("http3", b.dependency("zhttp3", .{}).module("http3"));
```

### C / C++

```sh
# Build produces libzhttp3.a and libzhttp3.so
# Include: include/zhttp3.h
# Link: -lzhttp3 -lzquic
```

---

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | QPACK — static table, Huffman, integer/string encoding, encoder/decoder | ✅ Done |
| 2 | HTTP/3 framing — DATA, HEADERS, SETTINGS, GOAWAY, control streams | ✅ Done |
| 3 | Server layer — comptime router, handler interface, middleware | ⬜ Planned |
| 4 | Language integrations — C API, handler ABI, example handlers | ⬜ Planned |
| 5 | WebAssembly — wasmtime embedding, hot reload | ⬜ Planned |
| 6 | Server push + GOAWAY | ⬜ Planned |

---

## Development

Requirements: Zig master (`0.16.0-dev` or later).

```sh
git clone https://github.com/ericsssan/zhttp3.git
cd zhttp3
zig build test
```

---

## Architecture

See [DESIGN.md](DESIGN.md) for the full design document.

---

## License

MIT — see [LICENSE](LICENSE).
