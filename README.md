# http

Pure HTTP field-value parsers: content negotiation, ranges, entity tags, dates, and media types.

No server. These are functions over bytes: parse a header value, negotiate a
content coding, compare validators. They take borrowed slices and fill
caller-owned storage, so there is no `std.Io` and no allocator in the API.

This project is incubating. It is unstable, its API will change, and it is not
ready to depend on.

## What is in it

- `encoding`: `Accept-Encoding` negotiation. `negotiate(header, supported)`
  returns a token borrowed from `supported` in server-preference order,
  `"identity"`, or `null` when the client accepts nothing else. The caller maps
  the token to its codec: `gzip`, `br`, `zstd`, or `deflate` for a zlib codec.

Ranges, entity tags, dates, media types, and form decoding are next. No server,
no middleware, and no request or response types: those depend on an I/O
runtime, and this package stops at the field value.

## Usage

```zig
const http = @import("http");

const coding = http.encoding.negotiate("gzip;q=0.5, br;q=1", &.{ "br", "gzip" });
// "br"
```

The token is borrowed from `supported`; `"identity"` is a static string. The
tests carry the q-value, wildcard, and identity rules.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs.

## License

MIT. See `LICENSE`.
