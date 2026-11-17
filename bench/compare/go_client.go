// The Go net/http side of the client comparison.
//
//	go run go_client.go -url http://127.0.0.1:9000/ -n 20000 -conc 1
//	go run go_client.go -url https://127.0.0.1:9444/ -n 20000 -conc 1 -h2
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

func main() {
	url := flag.String("url", "http://127.0.0.1:9000/", "request URL")
	total := flag.Int("n", 20000, "total requests")
	conc := flag.Int("conc", 1, "concurrent workers, one connection each")
	h2 := flag.Bool("h2", false, "require HTTP/2")
	flag.Parse()

	tlsConfig := &tls.Config{InsecureSkipVerify: true}
	if !*h2 {
		tlsConfig.NextProtos = []string{"http/1.1"}
	}
	transport := &http.Transport{
		TLSClientConfig:     tlsConfig,
		ForceAttemptHTTP2:   *h2,
		MaxIdleConns:        *conc,
		MaxIdleConnsPerHost: *conc,
		MaxConnsPerHost:     *conc,
		DisableCompression:  true,
	}
	client := &http.Client{Transport: transport}

	per := *total / *conc
	start := time.Now()
	var wg sync.WaitGroup
	errs := make([]error, *conc)
	for i := 0; i < *conc; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for j := 0; j < per; j++ {
				resp, err := client.Get(*url)
				if err != nil {
					errs[worker] = err
					return
				}
				_, err = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if err != nil {
					errs[worker] = err
					return
				}
			}
		}(i)
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
	}
	elapsed := time.Since(start)
	fmt.Printf("go %d %d\n", per**conc, elapsed.Nanoseconds())
}
