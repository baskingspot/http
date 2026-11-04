# Server engines

## Scope

`h1.engine.blocking` is a blocking HTTP/1 server over `std.Io`. It uses
`Io.Threaded` and `Io.net`. It serves one connection at a time. Use it for
tools, tests, and trusted peers. `h1.engine.poll` and `h1.engine.epoll` are the
readiness engines for the admin plane.

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

`run` reports a connection error through `Handler.VTable.report_error`. It then
accepts the next connection.

## Handler

A handler is `common.Handler`: a pointer plus a vtable. Every engine uses the
same type. The vtable has three required entries:

```zig
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, exchange: *Exchange) anyerror!void,
        complete: *const fn (ptr: *anyopaque, exchange: *Exchange) void,
        report_error: *const fn (ptr: *anyopaque, err: anyerror) void,
    };

    pub fn noopComplete(_: *anyopaque, _: *Exchange) void {}
    pub fn noopReportError(_: *anyopaque, _: anyerror) void {}
};
```

`handle` builds the response and must call `exchange.respond` before it
returns. `complete` runs once per exchange, after the final response bytes are
written or after the connection closes first. The exchange arena is still
readable there; the engine resets it after the callback. Do not respond from
`complete`. `report_error` runs after `handle` returns an error; the engine has
already queued the 500. A handler with no hooks passes `Handler.noopComplete`
and `Handler.noopReportError`.

A stateless handler passes `ptr = undefined`. A stateful handler sets `ptr` to
its state and casts it back in each function. The vtable is usually built by a
`handler()` method:

```zig
fn handler(self: *App) Handler {
    return .{ .ptr = self, .vtable = &.{
        .handle = handle,
        .complete = Handler.noopComplete,
        .report_error = reportError,
    } };
}
```

`handle` keeps `anyerror!void`. A vtable function pointer cannot carry a
precise error set, and the engine only reports it and sends the 500.

The exchange holds:

- The connection machine.
- The complete request.
- An engine-owned arena allocator.

The request body borrows the request buffer. Use it before the response
completes. The arena is valid from handler entry until `complete` returns.
Build the response body there with `std.fmt.allocPrint`, `allocator.alloc`, or
another allocator call, then pass the slice to `exchange.respond`.

The body passed to `respond` may also point at handler-owned memory that
outlives the response. In both cases the bytes must stay valid until the
response completes. The engine resets the arena with `arena_retain_bytes`
(default 16 KiB) after the completion callback, before the slot serves another
request or connection.

If `handle` returns an error before it responds, the engine queues a 500. If it
returns an error after it responds, the engine sends that response. The engine
reports the error through `report_error` in both cases. A handler that returns
without responding also gets a 500.

The handler is synchronous. It runs on the engine thread; a slow handler
blocks the other connections on that thread. A deferral hook is not part of
the blocking or readiness engines yet. Keep heavy work off the engine thread
until one exists. Completion notification is not a deferral hook: the handler
must respond before it returns.

## Connection behavior

The engine calls `advance` after a keep-alive response. A pipelined request in
the buffer is therefore handled without a read. The engine reads into
`ServerConn.recvBuffer` and writes `ServerConn.sendSlices` in order.

The request buffer holds the whole head and body. A body over `body_bytes` or
a body that does not fit the request buffer gets 413. A chunked request body
gets 501.

HEAD responses keep Content-Length and omit the body. A 204 or 304 response
omits Content-Length and the body. A 1xx status is not a final response.

## Readiness engines

`h1.engine.poll` and `h1.engine.epoll` are Linux-only for now. They share the
slot loop and differ only in registration and wait. `h1.engine.poll` builds a
`pollfd` array on every wait; `h1.engine.epoll` keeps a kernel registration and
changes it only when a slot's interest changes. `std.Io` supplies the listener,
the clock, and the listener close. The connection machine is the same
`h1.ServerConn`.

`Server` is a plain type, not a generic over the handler. The caller creates
it with an address, a `Handler`, and a `Config` that holds the allocator, the
slot count, the buffer sizes, the arena retain limit, the connection limits,
and the accept backoff. The server allocates all slots and buffers once, in
`init`; it allocates per request only when the handler uses the exchange
arena.

The methods are `init`, `run`, `stop`, `deinit`, and `port`. `run` blocks in
the wait backend. `stop` writes a stop eventfd; `run` returns after the next
wake.

The wait set contains:

- The stop eventfd.
- The listener, only when a slot is free and accept is not backed off.
- Every active slot, with read interest for read or drain and write interest
  for write.

The timeout is the earliest connection deadline or the accept-backoff
deadline. After each wait, the engine services readable and writable slots and
then expires due connections with `tick`. A head, body, or application timeout
queues a 408; a response or drain timeout closes. If the wait itself returns
`SystemResources`, the engine sleeps for the accept backoff and retries rather
than exiting.

The listener option `tcp_defer_accept` sets Linux `TCP_DEFER_ACCEPT` with a
one-second timeout. It is off by default; enable it when the server wants the
listener to wake only after the peer sends data.

A read feeds `recvBuffer` and `received`. A request calls the handler vtable.
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

The backend interface is `set`, `remove`, and `wait`. `h1.engine.poll` stores
the entries and builds a `pollfd` array in `wait`; `h1.engine.epoll` maps each
owner to an epoll registration. The slot state machine does not change.
Kqueue will use the same interface. io_uring is a separate completion engine.

## Future

The remaining evented engines are separate:

- Kqueue shares the readiness loop. It needs the portable listener, accept,
  and stop layer; epoll does not.
- io_uring has its own completion loop.
- Do not use `std.Io.Evented` for these engines. It is an experimental fiber
  runtime.
