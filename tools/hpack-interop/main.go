// Command hpack-interop writes tests/hpack-interop.txtar.
//
// The wire blocks come from golang.org/x/net/http2/hpack, pinned by go.mod and
// go.sum, so the fixture is an encoder this package did not write. Regenerate
// from the repository root with `just fixture`, or from this directory with
// `go run . > ../../tests/hpack-interop.txtar`. Go comes from the dev shell.
// This is a maintenance tool, not a build step.
package main

import (
	"bytes"
	"fmt"
	"strings"

	"golang.org/x/net/http2/hpack"
)

type message struct {
	name   string
	fields []hpack.HeaderField
	// table is the encoder's dynamic table size before this message; -1
	// leaves it alone.
	table int
}

func field(name, value string) hpack.HeaderField {
	return hpack.HeaderField{Name: name, Value: value}
}

const comment = `# HPACK interop fixture.
#
# Each message has two sections. NAME.wire is one complete header block in
# hex; NAME.fields is the field list it decodes to, one "name: value" per
# line, in order. The messages are one connection: blocks 2..6 reference
# dynamic table entries from earlier blocks.
#
# The blocks were produced by golang.org/x/net/http2/hpack at the version in
# tools/hpack-interop/go.mod, with the encoder's default indexing policy. The
# sequence covers a request and a response, repeated fields, a Set-Cookie
# pair, a Sensitive field (never indexed), a long value, and two dynamic table
# size updates with eviction down to 256 bytes and back.
#
# This is an interop fixture, not the specification. RFC 7541 Appendix C is
# the conformance set. Regenerate with: just fixture
`

func main() {
	messages := []message{
		{name: "request-1", table: -1, fields: []hpack.HeaderField{
			field(":method", "GET"),
			field(":scheme", "https"),
			field(":path", "/"),
			field(":authority", "www.example.com"),
			field("user-agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"),
			field("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
			field("accept-encoding", "gzip, deflate, br"),
			field("cookie", "session=abc123; theme=dark; lang=en-US"),
			field("x-trace-id", "0123456789abcdef0123456789abcdef"),
		}},
		{name: "request-2", table: -1, fields: []hpack.HeaderField{
			field(":method", "GET"),
			field(":scheme", "https"),
			field(":path", "/second"),
			field(":authority", "www.example.com"),
			field("user-agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"),
			field("accept-encoding", "gzip, deflate, br"),
			field("cookie", "session=abc123; theme=dark; lang=en-US"),
			field("x-trace-id", "0123456789abcdef0123456789abcdef"),
		}},
		{name: "response-1", table: -1, fields: []hpack.HeaderField{
			field(":status", "200"),
			field("content-type", "application/json; charset=utf-8"),
			field("content-length", "1234"),
			field("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
			field("set-cookie", "a=1; Path=/; HttpOnly"),
			field("set-cookie", "b=2; Path=/; SameSite=Lax"),
			field("cache-control", "private, max-age=60"),
			{Name: "authorization", Value: "Bearer 0123456789abcdef", Sensitive: true},
		}},
		{name: "request-3", table: -1, fields: []hpack.HeaderField{
			field(":method", "POST"),
			field(":scheme", "https"),
			field(":path", "/upload"),
			field(":authority", "www.example.com"),
			field("content-type", "application/octet-stream"),
			field("content-length", "1048576"),
			field("x-long", strings.Repeat("a", 264)),
		}},
		{name: "table-256", table: 256, fields: []hpack.HeaderField{
			field(":method", "GET"),
			field(":scheme", "https"),
			field(":path", "/small"),
			field(":authority", "www.example.com"),
			field("accept-encoding", "gzip, deflate, br"),
			field("cache-control", "private, max-age=60"),
		}},
		{name: "table-4096", table: 4096, fields: []hpack.HeaderField{
			field(":status", "304"),
			field("date", "Mon, 21 Oct 2013 20:13:22 GMT"),
			field("etag", `"33a64df551425fcc55e4d42a148795d9f25f89d4"`),
		}},
	}

	fmt.Print(comment)
	fmt.Println()

	var buf bytes.Buffer
	encoder := hpack.NewEncoder(&buf)
	for _, message := range messages {
		buf.Reset()
		if message.table >= 0 {
			encoder.SetMaxDynamicTableSize(uint32(message.table))
		}
		for _, header := range message.fields {
			if err := encoder.WriteField(header); err != nil {
				panic(err)
			}
		}

		fmt.Printf("-- %s.wire --\n", message.name)
		wire := buf.Bytes()
		for i := 0; i < len(wire); i += 16 {
			end := min(i+16, len(wire))
			for _, b := range wire[i:end] {
				fmt.Printf("%02x", b)
			}
			fmt.Println()
		}

		fmt.Printf("-- %s.fields --\n", message.name)
		for _, header := range message.fields {
			fmt.Printf("%s: %s\n", header.Name, header.Value)
		}
		fmt.Println()
	}
}
