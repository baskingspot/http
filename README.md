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
  `"identity"`, or `null` when the client accepts nothing else.
  `negotiateFields` takes every `Accept-Encoding` line, because the lines
  combine as one ordered list. The caller maps the token to its codec: `gzip`,
  `br`, `zstd`, or `deflate` for a zlib codec.
- `token_list`: comma-separated token lists (`Connection`, `Upgrade`, `Vary`).
  `contains(field, token)` tests membership without allocating; `iterator`
  yields trimmed elements. Empty elements are ignored, and the comparison
  folds ASCII case.
- `Field` / `Fields`: a borrowed field line and an ordered, case-insensitive
  view over a field section. `get` returns the first value for singleton
  fields, `values` yields every line separately (`Set-Cookie` needs that), and
  `containsToken` tests list membership across all lines. Lookups trim OWS;
  the raw spans stay in `Fields.items`.
- `content_length`: `Content-Length` parsing and combination. Repeated values
  must agree, a comma list of identical values is accepted, and non-digits,
  conflicts, and overflow are errors. `null` means the field was absent. The
  caller owns the rule that `Transfer-Encoding` and `Content-Length` cannot
  both frame a request.

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

```zig
const persistent = !http.token_list.contains("keep-alive, Upgrade", "close");
const length = try http.content_length.parse(&.{ "42", "42" }); // 42
```

## Work on it

`nix develop` provides the toolchain. `just ci` runs what CI runs, `just bench`
runs the benchmarks, and `just fuzz` drives the fuzz targets with the built-in
runner.

## License

MIT. See `LICENSE`.
