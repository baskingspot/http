# Client request-body streaming

Working notes for the h2 request-body work. Landed 2026-11-09 on `main` after
v0.2.0; the user-facing text is in `CHANGELOG.md`, `docs/spec/h2.md`, and the
guide.

## Landed shape

The client contract is a writable body, not a reader the adapter drains.
`h2.client.blocking.Client.begin(request)` queues the HEADERS with no
END_STREAM and returns a `client.BodyWriter`. `write(bytes)` submits DATA under
the stream and connection send windows, flushing whole frames and reading
events to let the windows open. `close()` sends END_STREAM. `response()` reads
the response head whenever the caller is ready, so a response may arrive while
the request body is still open.

Response DATA that arrives during a write is buffered in the adapter. Its flow
charge stays until `Body.read` hands it out and the following read supersedes
it, so the buffer is bounded by the connection window (65,535 by default).
`request()` and `Request.body` remain the static convenience: they run the same
writes and closes, except a final response that arrives before the body is sent
ends the send early and leaves the rest in `pending_body` for `Body.read`.

The h2 server side is `h2.engine.Config.body_mode = .stream`. The handler runs
on the request head, and `Exchange.request_body` is an `engine.stream.ReadStream`
returning `Pending`, `EndOfStream`, or `Canceled`. The handler is re-entered per
turn rather than parked on a stack frame; `Exchange.waitForProgress` ends a
turn. `beginResponse`, `write`, `endResponse`, and `resetStream` are the push
response API. Buffered `respond` is the convenience over the same pump.

## Accounting

- Credit for a body chunk returns when the handler asks for the next chunk.
  Stop reading and the peer sees no WINDOW_UPDATE.
- A reset (local or peer) returns the outstanding chunk and the unread bytes to
  the connection window only. The stream has no receive window left.
- `body_bytes` caps the aggregate request. Over the cap is RST_STREAM
  `ENHANCE_YOUR_CALM`; the engine never grows the buffer.
- DATA that arrives before the handler has a chunk to take stays charged, which
  is what stops the peer.

## Tests that pin it

- `tests/h2_streaming.zig` — two request/response messages on one stream while
  the request body is open; the over-cap reset; the mid-body reset reaching the
  writer.
- `src/h2/engine/connection.zig` — the stream engine answering twice before
  END_STREAM, chunk credit superseding, peer-reset credit, over-cap reset.
- `src/h2/client/blocking.zig` — the v0.1 behaviours that must not regress:
  early response with a static body, commit state on a failed END_HEADERS
  write, poison separate from commit.

## Not done

- h1 request-body streaming. `h1.ServerConn` delivers no incremental body and
  the h1 client writes `Request.body` in one call.
- `client.blocking.Client` (the protocol-neutral facade) has no `begin`; a
  caller that needs a streaming body uses the h2 adapter directly.
- A pull-based `respondStream(options, ResponseStream)` for h2. The push API
  covers the gRPC shape; a pull source needs an agreed non-blocking `Pending`
  contract, because `engine.stream.QueueStream` blocks.
