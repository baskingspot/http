<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="http" height="48">
  </picture>
</h1>

HTTP/1.1 and HTTP/2 in Zig: field-value parsers, sans-I/O connection machines, and the engines you build a server or client on.

Zig's `std.http` has an HTTP/1.1 client and server. It has no HTTP/2 and no
HPACK, and its request and response types come with a connection attached, so a
proxy, a test, or a server with its own event loop has nothing to call. This
package is that layer. `h1` and `h2` each hold parsers, a sans-I/O connection
machine, and engines; the parsers take bytes, return borrowed slices, fill
storage you own, and never allocate.

It is mid-level on purpose. There is no router, no middleware, and no request
type you cannot see through: `h1.ServerConn` and `h2.Session` hand you events,
and an engine is a listener and a handler loop around them.

```zig
const http = @import("http");

fn hostOf(bytes: []const u8) !?[]const u8 {
    var storage: [32]http.Header = undefined;
    var search: http.h1.SearchState = .init;
    const parsed = try http.h1.parseRequest(bytes, &search, &storage);
    return http.h1.host(parsed.head.headers); // borrows `bytes`
}
```

The library is pre-1.0 and the API is not frozen; a consumer pins a version.

## What is in it

- [Field values](https://baskingspot.dev/http/#field-values): `content_length.parse`, `encoding.negotiate`, `token_list.contains`, and `transfer_encoding.summarize` read one field family each, and `Cursor` is the byte position all of them walk.
- [Headers](https://baskingspot.dev/http/#headers): `Headers.get`, `values`, and `containsToken` look up a field section in wire order and fold ASCII case, and duplicate lines stay separate.
- [Method and status](https://baskingspot.dev/http/#method-and-status): `Method.parse` is case-sensitive, `Status` is an open enum so an unnamed three-digit code is still a value, and `WireVersion` keeps the exact digits.
- [The h1 message](https://baskingspot.dev/http/#the-h1-message): `h1.parseRequest` returns borrowed slices or `error.Incomplete`, `h1.framing` picks the body rule, `h1.chunked.Decoder` resumes mid-body, and `h1.Writer` writes the message back out.
- [The h1 connection machine](https://baskingspot.dev/http/#the-h1-connection-machine): `h1.ServerConn` and `h1.ClientConn` take the bytes you read and the time you have, and own no memory and no socket.
- [The h1 engines](https://baskingspot.dev/http/#the-h1-engines): `h1.engine.blocking.serve` takes one connection at a time, and `h1.engine.poll`, `.epoll`, and `.kqueue` serve fixed slots with deadlines.
- [The h2 session and frames](https://baskingspot.dev/http/#the-h2-session-and-frames): `h2.frame.parse` is the frame codec, and `h2.Session` owns SETTINGS, streams, flow control, HPACK, and CONTINUATION assembly.
- [HPACK](https://baskingspot.dev/http/#hpack): `hpack.Decoder` and `hpack.Encoder` keep the static and dynamic tables in step, and `prefix_int` and `huffman` are the primitives QPACK reuses.
- [The client contract](https://baskingspot.dev/http/#the-client-contract): `client.Request` and `client.Body` are protocol-neutral, and `client.blocking.Client` dispatches to an h1 or an h2 adapter.
- [Running a server](https://baskingspot.dev/http/#running-a-server): `engine.Handler(Exchange)` is the one vtable every engine calls, and `http_tls` adds TLS without putting crypto in the core.
- [Performance](https://baskingspot.dev/http/#performance): 81 ns against 79 ns on a typical request head, 255 ns against 334 ns on a wide one, and 3.8x on a 1 KiB header value.
- [Limits](https://baskingspot.dev/http/#limits): no streaming request bodies, no connection reuse, and the rest of what is not here.

Not implemented:

- Streaming request bodies: `client.Request.body` is a `[]const u8`, and an engine's `Exchange.request.body` is the whole body up to `Config.body_bytes`.
- Chunked request bodies on the server: `h1.ServerConn` answers 501 with `RejectReason.chunked_unsupported`.
- Response trailers: `h1.ClientConn` parses them into `Config.trailers`, and `client.ResponseHead` has no trailer list, so the fields are dropped.
- Connection reuse and pooling: `h1.client.blocking.fetch` does not reuse the connection, and nothing in `http.client` pools one.
- Redirects: a 3xx comes back as a `client.Response` with its `Status`; nothing follows it.
- Cookies: `Headers` never combines `Set-Cookie`, h2 `cookie` lines stay separate, and there is no jar.
- Routing: `h1.targetForm` classifies the target and stops. There is no router and no method dispatch.
- Middleware: `engine.Handler` is one vtable with four entries, and nothing chains around it.
- Server push: a received `PUSH_PROMISE` is a connection error `PROTOCOL_ERROR`.
- HTTP/3: there is no `h3` namespace, no QPACK, and no QUIC varint.

## Install

```sh
zig fetch --save https://baskingspot.dev/http/v0.2.0.tar.gz
```

Add the module in `build.zig`:

```zig
const http = b.dependency("http", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("http", http.module("http"));
```

`std.http` keeps its name, so `http` sits beside it in the same file. The
package also exports `http_tls`, a second module for the TLS readiness engines;
import it only when the server terminates TLS. `http` builds with Zig 0.16 only.

## Documentation

- The [guide](https://baskingspot.dev/http/) says which piece to use for a task, with the symbols and the code.
- The [API reference](https://baskingspot.dev/http/api/) documents every public symbol in `src/root.zig`.
- [`examples/`](examples/) runs every engine, the two clients, and a small curl. `just check-example` builds all of them.
- [`CHANGELOG.md`](CHANGELOG.md) records what moved in the API.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain. `just` lists the recipes, and `just ci`
runs what CI runs: the unit tests, lint, the Go interop server, the example
builds, and h2spec in strict mode against the readiness and TLS examples.

`just bench` runs the benchmarks at `ReleaseFast`, `just fuzz 50M` drives the
fuzz targets, and `just example` starts the HTTP/1.1 server on 127.0.0.1:8080.
`just conformance-run` starts the h2c example and runs h2spec against it.
`just doc` builds the site into `zig-out/site/http/`, and `just guide` serves it
with live reload.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are baskingspot
marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
