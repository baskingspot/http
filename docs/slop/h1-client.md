# HTTP/1 client shape

Snapshot 2026-11-04. There is no client in the package. The parser already has
`parseResponse`, `framing.response`, and the chunked decoder; `Writer` already
writes a request. The missing piece is the connection state machine.

## Recommendation

Build a sans-I/O `h1.ClientConn` first, not a blocking `fetch`. It mirrors
`ServerConn`: the caller owns the receive buffer and header storage, feeds
bytes, and gets borrowed response heads and body slices. Blocking and readiness
adapters can then sit above it without deciding the parser's API twice.

Request serialization should stay separate. The caller uses `h1.Writer` into a
buffer with its own `std.Io.Writer`, then sends those bytes. `ClientConn` owns
the response side only. This keeps the request head and body out of the client
machine and avoids giving it an allocator.

## Scope

In:

- One request at a time on a connection.
- Response head parsing, including interim 1xx responses.
- Body framing for `Content-Length`, chunked, close-delimited, and no-body
  responses (HEAD, 204, 304).
- Keep-alive and leftover bytes for the next response.
- Body streaming: the caller consumes body slices without the machine buffering
  the whole body.

Out:

- Redirects, retries, cookies, proxies, and TLS.
- Concurrent requests on one connection.
- Automatic request headers. The caller supplies Host and any framing it wants,
  except that a convenience helper can add Content-Length for a known body.

Close-delimited responses end the connection. A 101 or CONNECT tunnel is a
handoff, not an HTTP body; leave that to the caller for now.

## API sketch

```zig
var client = h1.ClientConn.init(.{
    .recv_buffer = &recv,
    .headers = &headers,
    .body_bytes = 64 * 1024,
});

client.start(.GET);                 // request method drives HEAD/204/304
const dst = client.recvBuffer();    // read into this
switch (client.received(n)) {
    .need_more => continue,
    .response => |head| { ... },    // final or interim
    .body => |bytes| { ... },       // borrowed, consume now
    .done => { ... },               // response complete
    .closed => { ... },
}
```

The exact event split is open. The important property is that body bytes are
borrowed from the receive buffer and valid until the next read, the same rule
as `ServerConn`. A body reader can be layered over the machine if events become
awkward.

Lifetimes match the server: the returned head borrows the receive buffer and
the caller's header storage. The caller must copy a field before reading more
bytes or reusing the buffer. `ClientConn.start` resets the per-response parser
state; it does not allocate.

## Body handling

`framing.response` already selects the framing. For `.length`, count down and
report body slices as bytes arrive. For `.chunked`, feed the existing
`chunked.Decoder` and expose decoded slices; trailers are validated and
discarded unless a caller asks for them. For `.close`, every byte until EOF is
body; after EOF the connection cannot be reused.

A body limit applies to the bytes delivered to the caller, not to buffering,
because the machine never buffers the body. If a zero-copy streaming body is
not wanted, a later convenience adapter can fill a caller buffer.

## Keep-alive

After a complete response, leftover bytes in the receive buffer are the start
of the next response. `start` must not discard them. The machine needs a
`finished`/`advance` step analogous to `ServerConn.advance` so a pipelined
response is parsed without a read.

`Connection: close`, HTTP/1.0 without keep-alive, close-delimited framing, and
EOF end reuse. A 1xx head is not final and must not reset the connection.

## First slice

1. `ClientConn` with `Content-Length`, no-body, and close-delimited framing.
2. Raw-socket tests for HEAD, 204, 304, interim 100, split head, truncated body,
   and EOF before the head.
3. Chunked bodies through `chunked.Decoder`.
4. A blocking adapter over `std.Io.net` for tests and tools.
5. Interop against a Go `net/http` server once a body streaming API is settled.

No client code should grow an allocator. If a caller wants an owned response,
the adapter can offer one above `ClientConn`.
