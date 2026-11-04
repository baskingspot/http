// Command http1-interop is a Go net/http server for the HTTP/1 client lane.
//
// It is deliberately small: the Zig client in examples/http1_client.zig
// checks Content-Length, chunked, and request-body echo against a mature
// server implementation.
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, "hello from go\n")
	})
	http.HandleFunc("/chunked", func(w http.ResponseWriter, _ *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flusher", http.StatusInternalServerError)
			return
		}
		fmt.Fprint(w, "one")
		flusher.Flush()
		fmt.Fprint(w, "two")
		flusher.Flush()
	})
	http.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.Copy(w, r.Body); err != nil {
			log.Printf("echo: %v", err)
		}
	})

	log.Print("http1-interop listening on 127.0.0.1:8091")
	log.Fatal(http.ListenAndServe("127.0.0.1:8091", nil))
}
