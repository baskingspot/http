# AGENTS.md

Working notes for AI coding agents in baskingspot/http.

## What this is

Pure HTTP field-value parsers: content negotiation, ranges, entity tags, dates, and media types. It is incubating: unstable, with no promises about its API.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit.

## Design

- Pure functions over bytes. No `std.Io`, no allocator, no server types, and
  no dependency on `compress`. A parser takes a slice and returns borrowed
  slices or fills caller-owned storage; a list parser is an iterator.
- No server, no middleware, no request or response types, and no header map.
  Those depend on the host's I/O runtime; this package stops at the field
  value.
- Tokens stay slices; do not freeze a registry in an enum. `encoding` returns
  the caller's own token, and the caller maps `deflate` to a zlib codec, `br`
  to brotli, and so on.
- One module per field family. The root exports namespaces:
  `pub const encoding = @import("encoding.zig");`.
- Tests cite the RFC section they pin. Every parser gets hostile-input cases;
  a parser with a loop gets a fuzz target.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint` run both.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
