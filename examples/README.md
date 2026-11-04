# HTTP/1.1 examples

## Blocking server

```sh
just example
curl -v http://127.0.0.1:8080/
```

The server uses `engine.blocking` over `std.Io`. The engine accepts one
connection at a time and calls a handler with a complete request. The handler
formats a response body into the per-connection scratch and calls
`conn.respond`. The connection machine handles head parsing, body framing,
keep-alive, pipelining, `Expect: 100-continue`, and the policy responses.

There are no timeouts, no concurrency, and no TLS. A blocking syscall cannot
enforce the connection deadlines, so the blocking engine sets every timeout to
zero. A chunked request body gets 501 for now. The poll engine will replace
this one for the admin plane.

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
