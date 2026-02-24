# Contributing to zhttp3

zhttp3 is early-stage software. Contributions are welcome.

## Before You Start

- Check the [open issues](https://github.com/ericsssan/zhttp3/issues) to avoid duplicate work.
- For significant changes, open an issue first to discuss the approach.

## Development Setup

Requirements: Zig master (`0.16.0-dev` or later).

```sh
git clone https://github.com/ericsssan/zhttp3.git
cd zhttp3
zig build test
```

## Code Style

- Follow the style of the surrounding code.
- No allocations in hot paths — the design is pre-allocated buffers.
- Every new module must have tests. Run `zig build test` before submitting.
- Zig `std.debug.assert` for invariants, not runtime errors.

## Pull Request Process

1. Fork the repo and create a branch: `git checkout -b your-feature`
2. Write tests that cover your changes.
3. Ensure `zig build test` passes.
4. Open a PR with a clear description of what and why.

## RFC Compliance

All QPACK and HTTP/3 behavior must match the relevant RFCs:
- [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114) — HTTP/3
- [RFC 9204](https://www.rfc-editor.org/rfc/rfc9204) — QPACK
- [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541) — HPACK (Huffman table)

When in doubt, the RFC is authoritative.
