# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Status`: the status codes as an open enum. Named codes are constants; any
  other three-digit code is still a value. `Status.code()`, `Status.class()`,
  `Status.phrase()`, and `Status.parse()` work on the wire number, and the
  parser returns `Status` directly.
- `Method`: the conventional nine request methods as a local enum, with
  `Method.token()`, the case-sensitive `Method.parse()`, and the RFC 9110
  §9.2 predicates.
- `Header`, `Headers`, and `Headers.values`: borrowed field lines and ordered,
  case-insensitive lookup over a field section. Duplicate lines are yielded
  separately, and lookups trim OWS.
- `Headers.containsToken`: list-element membership across every line with a
  given name.
- `encoding.negotiate`: `Accept-Encoding` parsing and content-coding
  negotiation over the q-value, wildcard, and identity rules. The chosen
  token is borrowed from the caller's supported list.
- `encoding.negotiateFields`: the same negotiation across multiple field
  lines, which combine as one ordered list.
- `token_list.contains` and `token_list.iterator`: comma-separated token
  lists such as `Connection` and `Upgrade`, with OWS handling and
  case-insensitive membership.
- `h1.parseRequest` and `h1.parseResponse`: sans-I/O HTTP/1.1 head parsing.
  `RequestHead.method` is `?Method` and `method_token` keeps the exact wire
  bytes; `ResponseHead.status` is `Status`; `version` is the effective version
  after RFC 9110 §6.2 and `wire_version` keeps the wire pair. Both heads carry
  `Headers`. Both report `error.Incomplete` until a whole head arrives, take
  a `SearchState` for a resumable completeness check, and reject bare LF,
  obs-fold, and whitespace before the colon.
- `h1.framing.request` and `h1.framing.response`: body framing per RFC 9112
  §6.3. A request returns `RequestBody`: `.none`, `.length`, or `.chunked`. A
  response returns `ResponseBody`, which adds `.close` and `.tunnel`. TE with
  CL, TE on an HTTP/1.0 message, and a request whose final coding is not
  `chunked` are errors.
- `h1.persistent`: the RFC 9112 §9.3 connection decision from the version and
  the `Connection` tokens. HTTP/1.1 persists by default; HTTP/1.0 persists
  only with `keep-alive`; `close` wins.
- `h1.parseFieldSection`: a standalone field section and the trailer parser.
  An empty section is a single CRLF; the returned headers borrow the input and
  the caller's storage.
- `h1.chunked.Decoder`: resumable chunked transfer coding (RFC 9112 §7.1).
  `next` returns a borrowed data slice, the trailer `Headers`, or `need_more`,
  with the consumed prefix on every step. Chunk extensions are parsed and
  ignored; a chunk-size overflow is `error.Overflow`.
- `h1.Writer`: carries a caller-owned `std.Io.Writer` and writes request/status
  lines, field lines, Content-Length, body bytes, and chunked bodies with
  trailers. Checked methods validate the parser's grammar; the `assume*`
  variants skip validation for trusted data. The writer never allocates,
  flushes, or closes the sink.
- `transfer_encoding.summarize`: the `Transfer-Encoding` coding list in field
  order, with the final coding, a seen/last `chunked` flag, parameter parsing
  (including quoted values), and rejection of repeated or parameterized
  `chunked`.
- `content_length.Parser`: `Content-Length` accumulation one field line at a
  time for a caller that already has a field view. `parse` remains the slice
  form.
- `Version` and `WireVersion`: the effective version and the exact wire pair,
  exported at the package root and from `h1`.
- `content_length.parse`: `Content-Length` parsing and duplicate
  combination. Conflicting values, non-digits, and overflow are errors;
  `null` means the field was absent.

### Changed

- `h1.parseRequest`, `h1.parseResponse`, and `h1.parseFieldSection` take a
  `SearchState` instead of a raw `last_len`. The parser records the searched
  length on `error.Incomplete` and clears it after a complete parse.
- The package owns its public types. `Header`, `Method`, `Status`, and
  `h1.Version` no longer alias `std.http`.
- The package depends on `baskingspot/stdx` for `stdx.fmt.atoi`;
  `content_length` parses its digits with it.
