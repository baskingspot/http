# Server engines

## Scope

`h1.engine.blocking` is a blocking HTTP/1 server over `std.Io`. It uses
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

`run` reports a connection error through `Handler.onError` when the handler
provides it. It then accepts the next connection.

## Handler

A handler is a comptime type. The engine calls `Handler.handle` with an
`Exchange`. The type must provide:

```zig
pub fn handle(self: *Handler, exchange: *Exchange) anyerror!void
```

It may provide:

```zig
pub fn onError(self: *Handler, err: anyerror) void
```

`run` and `serve` take the handler type and a pointer to the handler value.
There is no function pointer or `?*anyopaque` context. The handler type is
known when the engine is compiled.

The exchange holds:

- The connection machine.
- The complete request.
- A response body scratch buffer.

The request body borrows the request buffer. Use it before the response
completes. The response body scratch stays valid until the response completes.
A handler formats the body there and calls `exchange.respond`.

The body passed to `respond` may also point at handler-owned memory that
outlives the response. The per-slot scratch is a convenience, not a limit;
do not size it for the largest possible body.

If `handle` returns an error before it responds, the engine queues a 500. If it
returns an error after it responds, the engine sends that response. The engine
reports the error through `onError` in both cases. A handler that returns
without responding also gets a 500.

The handler is synchronous. It runs on the engine thread; a slow handler
blocks the other connections on that thread. A deferred response hook is not
part of the blocking or poll engine yet. Keep heavy work off the poll thread
until such a hook exists.

## Connection behavior

The engine calls `advance` after a keep-alive response. A pipelined request in
the buffer is therefore handled without a read. The engine reads into
`ServerConn.recvBuffer` and writes `ServerConn.sendSlices` in order.

The request buffer holds the whole head and body. A body over `body_bytes` or
a body that does not fit the request buffer gets 413. A chunked request body
gets 501.

HEAD responses keep Content-Length and omit the body. A 204 or 304 response
omits Content-Length and the body. A 1xx status is not a final response.

## Poll engine

`h1.engine.poll` is Linux-only for now. It uses `poll(2)` over raw nonblocking
descriptors. `std.Io` supplies the listener, the clock, and the listener close.
The connection machine is the same `h1.ServerConn`.

`Server(Handler)` takes the handler type at comptime. The caller creates it
with an address, a handler pointer, and a `Config` that holds the allocator,
the slot count, the buffer sizes, the connection limits, and the accept
backoff. The server allocates all slots and buffers once, in `init`; it does no
allocation per request.

The methods are `init`, `run`, `stop`, `deinit`, and `port`. `run` blocks in
`poll`. `stop` writes a stop eventfd; `run` returns after the next wake.

The poll set contains:

- The stop eventfd.
- The listener, only when a slot is free and accept is not backed off.
- Every active slot, with `POLLIN` for read or drain and `POLLOUT` for write.

The timeout is the earliest connection deadline or the accept-backoff
deadline. After each wait, the engine services readable and writable slots and
then expires due connections with `tick`. A head, body, or application timeout
queues a 408; a response or drain timeout closes.

A read feeds `recvBuffer` and `received`. A request calls the comptime handler.
A write sends `sendSlices` and calls `sent`. After 100 Continue the slot
returns to read. After keep-alive the engine calls `advance` before the next
read, so a pipelined request needs no syscall. `.close_after_drain` switches
the slot to drain; the engine reads into scratch and discards until EOF or the
drain deadline.

Accept uses `accept4` in a loop. `EMFILE`, `ENFILE`, and resource exhaustion
pause the listener for the accept backoff, which defaults to 50 ms. A full slot
table means the listener is not polled; the backlog holds the connection. The
engine checks for a free slot before it accepts, so it never accepts and closes
a connection just because slots are full.

The listener is opened with `SO_REUSEADDR` only. It does not set
`SO_REUSEPORT`, so two processes cannot silently bind the same port.

Epoll and kqueue replace the wait and registration part of this loop. The slot
state machine does not change. io_uring is a separate completion engine.

## Future

The remaining evented engines are separate:

- Epoll and kqueue share the poll engine's readiness loop.
- io_uring has its own completion loop.
- Do not use `std.Io.Evented` for these engines. It is an experimental fiber
  runtime.
