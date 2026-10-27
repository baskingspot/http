# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `StatusCode`: the status codes as an exhaustive enum derived from
  `std.http.Status`, with `status.code`, `status.parse`, and `status.phrase`.
- `Method`: `std.http.Method` re-exported, plus `method.token` and the
  case-sensitive `method.parse`.
- `Header` (`std.http.Header`), `Headers`, and `Headers.values`: borrowed
  field lines and ordered, case-insensitive lookup over a field section. Duplicate lines are yielded
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
- `h1.parseRequest` and `h1.parseResponse`: sans-I/O HTTP/1.1 head parsing
  into shared `Headers`. Both report `error.Incomplete` until a whole head
  arrives, take `last_len` for a resumable completeness check, and reject bare
  LF, obs-fold, and whitespace before the colon.
- `content_length.parse`: `Content-Length` parsing and duplicate
  combination. Conflicting values, non-digits, and overflow are errors;
  `null` means the field was absent.

### Changed

- The package depends on `baskingspot/stdx` for `stdx.fmt.atoi`;
  `content_length` parses its digits with it.
