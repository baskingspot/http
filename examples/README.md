# HTTP/1.1 examples

## Blocking server

```sh
just example
just curl http://127.0.0.1:8080/
```

The server uses `h1.engine.blocking` over `std.Io`. The accept loop owns the
listener and moves each accepted stream into a task in an `Io.Group`. One task
serves one connection and owns its own buffers. The engine calls a handler with
a complete request. The handler formats a response body with the exchange arena
and calls `exchange.respond`. The connection machine handles head parsing,
body framing, keep-alive, pipelining, `Expect: 100-continue`, and the policy
responses.

The example uses `Group.concurrent` rather than `Group.async`. The async form
may run the task inline when the pool is busy, and a slow client would then
stall the accept loop.

The default `std.Io.Threaded` backend runs each task on its own thread, so this
is a thread per live connection. It is an example, not a server to deploy.

There are no timeouts and no TLS. A blocking syscall cannot enforce the
connection deadlines, so the blocking engine sets every timeout to zero. A
chunked request body gets 501 for now. The poll engine will replace this one
for the admin plane.

## Poll server

```sh
just example-poll
```

Linux only for now. The same handler as the blocking example runs over the
poll engine: fixed slots, nonblocking sockets, connection deadlines, accept
backoff, keep-alive and pipelining, and a stop eventfd.

## Epoll server

```sh
just example-epoll
```

Linux only. The same handler and readiness loop as the poll example, with
epoll doing registration and the wait. The slot state machine is shared; the
poll engine builds a `pollfd` array on every wait, and this one keeps kernel
registrations and changes them only when a slot's interest changes.

## Kqueue server

```sh
just example-kqueue
```

macOS only. The same handler and readiness loop as the poll example, with
kqueue read and write filters doing registration and the wait. The platform
edge uses `accept` plus `fcntl` and a pipe for the stop descriptor.

## io_uring

```sh
just example-uring
```

Linux only. A client and server in one process, with io_uring driving every
socket read and write after a blocking accept. The client sends two pipelined
requests; the second is already in the receive buffer after the first head, so
the server has to consume the first request and move the leftover forward
before parsing again.

The server answers the first request with a chunked response; the client parses
the response head and decodes the body. This is the useful stress test for the
API: the parser sees a buffer that may hold a head, a body, and the next
request, and the head slices go stale as soon as the buffer is reused.

## HTTP/1 client interop

```sh
just interop
```

Builds `tools/http1-interop`, starts its Go `net/http` server on
127.0.0.1:8091, and runs `examples/http1_client.zig` against the
Content-Length, chunked, and request-body echo routes. The client uses
`h1.client.blocking.fetch` with caller-owned buffers.

## HTTP/1.1 over TLS

```sh
just example-h1-tls          # server on 127.0.0.1:8444
just example-h1-tls-client   # in another terminal
```

The server and client use the blocking `tls_std` integration from
`baskingspot/tls` and ALPN `http/1.1`. The HTTP code sees only plaintext
`Io.Reader` and `Io.Writer` interfaces; `just interop-tls` runs the pair in CI.
The example certificate and scalar are the public test fixture from
`baskingspot/tls`.

## One port, both protocols

```sh
just example-unified       # TLS on 8445, cleartext on 8082
just curl -k https://127.0.0.1:8445/
just curl --http2 http://127.0.0.1:8082/
curl http://127.0.0.1:8082/
```

The TLS listener offers `h2` and `http/1.1` through ALPN and dispatches the
blocking engine after the handshake. The cleartext listener reads the HTTP/2
connection preface; anything else is HTTP/1.1.

## Deferred handlers

```sh
just example-deferred
just curl -s http://127.0.0.1:8093/
```

The handler calls `exchange.deferResponse`, returns, and starts one
`Io.async` task. The task calls `exchange.wake()` when its result is ready.
The poll engine resumes the callback on its own thread, so other connections
continue to run while the request waits. The cancel callback runs if the
client disconnects or the request deadline expires before the response.

## Pull-based response streams

```sh
just example-sse             # blocking SSE, 127.0.0.1:8090
just example-sse-poll        # poll-engine SSE, 127.0.0.1:8092
just curl -s http://127.0.0.1:8090/
just curl -s http://127.0.0.1:8092/
just example-stream README.md
just curl -s http://127.0.0.1:8091/ > /tmp/readme.xor
```

The handler returns a `http.stream.ReadStream`; the engine writes the head,
pulls one chunk when it can accept it, and frames an unknown length as chunked
on HTTP/1.1. The terminal chunk returns the connection to keep-alive; HTTP/1.0
uses a close-delimited body. The SSE examples feed the stream through an `Io.Queue` pipe and start the
producer with `Io.async`, so closing the queue wakes the producer with
`error.Closed`. `sse_poll.zig` uses `h1.engine.poll`; its source returns
`pending` when the queue is empty, and the engine checks the queue again
without blocking the other slots. `stream_pipeline.zig` reads a file in 16 KiB
chunks and XORs each chunk before returning it, standing in for a compression
or cipher transform.

## Tiny curl

```sh
just curl http://127.0.0.1:8080/
just curl --http2 http://127.0.0.1:8081/
just curl -k --http1.1 https://127.0.0.1:8445/
just curl -d hello -X POST http://127.0.0.1:8080/
just curl -I http://127.0.0.1:8080/
just curl -s -H 'X-Test: value' http://127.0.0.1:8080/
just curl -v -k https://127.0.0.1:8445/
just curl -s https://example.com/
```

Headers go to stdout before the body; the body streams. `-s` suppresses the
headers. Hosts can be DNS names or IP literals. HTTPS verifies the system trust
store by default; `-k` skips verification for the local fixtures. `-v` prints
the resolved address, request headers and body, response status and headers,
ALPN, cipher suite, and retained certificate chain.
`--http2` is h2c prior knowledge on cleartext and forces h2 in ALPN;
`--http1.1` forces h1. `-d` sends a static request body, `-X` changes the
method, `-H` adds a header, and `-I` sends HEAD.
