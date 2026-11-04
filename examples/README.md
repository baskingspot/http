# HTTP/1.1 examples

## Blocking server

```sh
just example
curl -v http://127.0.0.1:8080/
```

The server is deliberately small and single-connection. It shows the shape the
library expects:

- `h1.parseRequest` over a `std.Io.net.Stream.Reader`, with a `SearchState` and
  `error.Incomplete`.
- `h1.framing.request` to decide the body, then `readSliceAll` for a known
  length.
- `h1.persistent` for the connection decision.
- `Headers.containsToken`, `Method.token`, `Status.phrase`, and `Version` in the
  response.

Two lifetimes matter. The head borrows both the header storage and the reader's
buffer, so the target is copied and keep-alive is computed before the body read;
the read may rebase the buffer. The response body is written before the loop
returns to the next head.

A chunked request is decoded, including its trailer section. A body over
64 KiB gets 413. There are no timeouts, no concurrency, and no TLS; those belong
to the server above this package.

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
