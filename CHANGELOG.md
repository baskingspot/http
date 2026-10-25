# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `encoding.negotiate`: `Accept-Encoding` parsing and content-coding
  negotiation over the q-value, wildcard, and identity rules. The chosen
  token is borrowed from the caller's supported list.
