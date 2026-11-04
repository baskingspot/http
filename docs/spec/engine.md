# Blocking engine

## Scope

`engine.blocking` is a blocking HTTP/1 server over `std.Io`. It uses
`Io.Threaded` and `Io.net`. It serves one connection at a time. Use it for
tools, tests, and trusted peers. The poll engine is the engine for the admin
plane.

The parser modules stay sans-I/O. The engine owns the transport, the buffers,
the accept loop, and the handler call. `h1.ServerConn` owns the request state
machine.

## Loop

`run` accepts a stream and calls `serve`. `serve` drives one connection until
the peer closes or a response requires a close. The engine writes a policy
response that `h1.ServerConn` queued.

The engine sets all `h1.ServerConn.Limits` timeouts to zero. A blocking read or
write cannot enforce a deadline. A zero drain timeout makes a reject close
without a drain.

The accept loop handles these errors:

- `ConnectionAborted` and `WouldBlock` continue.
- `ProcessFdQuotaExceeded`, `SystemFdQuotaExceeded`, and `SystemResources` wait
  one second and continue.
- `Canceled` returns.
- Any other error returns.

`run` reports a connection error through `Handler.on_error`. It then accepts
the next connection.

## Handler

`Handler` has a context, a `handle` function, and an `on_error` function. The
engine calls `handle` with an `Exchange`. The exchange holds:

- The connection machine.
- The complete request.
- A response body scratch buffer.

The request body borrows the request buffer. Use it before the response
completes. The response body scratch stays valid until the response completes.
A handler formats the body there and calls `exchange.respond`.

If `handle` returns an error before it responds, the engine queues a 500. If it
returns an error after it responds, the engine sends that response. The engine
reports the error through `on_error` in both cases.

The handler is synchronous. A deferred response is not supported.

## Connection behavior

The engine calls `advance` after a keep-alive response. A pipelined request in
the buffer is therefore handled without a read. The engine reads into
`ServerConn.recvBuffer` and writes `ServerConn.sendSlices` in order.

The request buffer holds the whole head and body. A body over `body_bytes` or
a body that does not fit the request buffer gets 413. A chunked request body
gets 501.

HEAD responses keep Content-Length and omit the body. A 204 or 304 response
omits Content-Length and the body. A 1xx status is not a final response.

## Future

The evented engines are separate:

- Poll, epoll, and kqueue share a readiness loop.
- io_uring has its own completion loop.
- Do not use `std.Io.Evented` for these engines. It is an experimental fiber
  runtime.
