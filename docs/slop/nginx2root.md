# nginx2root and the HTTP/2 send window

Date: 2026-11-18. CVE-2026-123007.

## The nginx bug

nginx deducts a DATA frame's length from the connection and stream send
windows when it queues the frame. If the client resets the stream before the
frame leaves the queue, cleanup returns that length to the connection window.
A `WINDOW_UPDATE` between queuing and cleanup already returned the same bytes,
so the same quantity was added twice. The connection window passed 2^31-1 with
no bound check. The next check, `window > MAX - send_window`, subtracted in
unsigned arithmetic and wrapped, so every later `WINDOW_UPDATE` was accepted.
The window was then cast to a signed `off_t`; a value near 2^64 became a small
negative size. A shadow buffer computed `last = pos + size`, `last - pos`
became a huge `size_t`, and the TLS copy turned it into an out-of-bounds read
and write.

Source: <https://xint.io/blog/nginx2root-remote-code-execution>, section 5.1.

## Why http cannot express it

`src/h2/flow.zig` owns every window. `Window.available` is `i64`, and
`increase` computes the sum before comparing it with `max_window`. There is no
unsigned subtraction and no signed cast on the result.

Credit is consumed only when `Session.submitData` emits DATA into the output
queue. The accepted length is clamped by the stream window, the connection
window, the peer's maximum frame size, and the output budget. `submitData`
returns the number of bytes it accepted; the caller keeps the rest. There is no
reserved-credit ledger and no refund on `RST_STREAM`. `onRstStream` removes the
stream and leaves the already-queued frame alone.

The receive side mirrors this. `onData` consumes `header.length`, grants
padding immediately, and the engine releases only the unpadded data length
after the handler consumes it. The client mux uses the same Session windows;
its per-stream charge is bounded by the receive window.

The CVE needs three conditions. None exists here:

1. A send window that can be credited without a bound check. Every increase
   goes through `Window.increase`, which rejects a result above 2^31-1.
2. An unsigned subtraction in the bound check. The check is a signed compare
   on `i64`.
3. A window value used as a signed copy length. No path uses a window value as
   a buffer length; accepted bytes are the copy length.

`SETTINGS_INITIAL_WINDOW_SIZE` can shrink a stream window below zero. That is
the one negative value, and `Window.consume` and `Window.increase` handle it
explicitly.

## Tests

- `src/h2/session.zig`: "the nginx2root window sequence cannot overrun the
  send window". It replays the sequence against a server session and asserts
  the connection window stays at 2^31-1 through the reset, then gets
  `GOAWAY(FLOW_CONTROL_ERROR)` on the next increment.
- `tests/engine_h2.zig`: "the nginx2root window sequence ends in a
  flow-control GOAWAY". It drives the same sequence over a loopback socket
  against the direct engine, with half the response body sent before the
  reset.

Mutation check: removing the `next > max_window` check makes the session test
fail because the final increment is accepted.

## Residual

The PING flood in the nginx writeup fills the transport buffers. It is not the
root cause. This session allows control-frame output past `max_out_bytes`, so a
peer that floods PINGs while not reading could grow that queue in the
readiness engine. This was not tested here. That is a memory-bound concern to revisit separately. It cannot
produce the window overflow.
