# HTTP/1.1 examples

## Blocking server

```sh
just example
curl -v http://127.0.0.1:8080/
```

The server uses `h1.engine.blocking` over `std.Io`. The accept loop owns the
listener and moves each accepted stream into a task in an `Io.Group`. One task
serves one connection and owns its own buffers. The engine calls a handler with
a complete request. The handler formats a response body into the connection
scratch and calls `conn.respond`. The connection machine handles head parsing,
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
