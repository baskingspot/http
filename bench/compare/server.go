// A fixed reference server for the client comparison: one keep-alive
// connection per client, a 13-byte body, no logging.
//
//	go run server.go -addr 127.0.0.1:9000
//	go run server.go -addr 127.0.0.1:9443 -tls -alpn h1
//	go run server.go -addr 127.0.0.1:9444 -tls -alpn h2
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"sync/atomic"
	"net"
	"net/http"
	"time"
)

const body = "hello bench!\n"

func main() {
	addr := flag.String("addr", "127.0.0.1:9000", "listen address")
	useTLS := flag.Bool("tls", false, "serve TLS")
	alpn := flag.String("alpn", "h1", "TLS ALPN: h1 or h2")
	flag.Parse()

	var conns, requests atomic.Int64
	mux := http.NewServeMux()
	mux.HandleFunc("/count", func(w http.ResponseWriter, r *http.Request) {
		body := fmt.Sprintf("%d %d\n", conns.Load(), requests.Load())
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		io.WriteString(w, body)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", "13")
		io.WriteString(w, body)
	})

	srv := &http.Server{
		Addr:     *addr,
		Handler:  mux,
		ErrorLog: log.New(io.Discard, "", 0),
		ConnState: func(_ net.Conn, state http.ConnState) {
			if state == http.StateNew {
				conns.Add(1)
			}
		},
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	if !*useTLS {
		fmt.Println("server:", *addr, "cleartext h1")
		log.Fatal(srv.Serve(ln))
	}

	protos := []string{"http/1.1"}
	if *alpn == "h2" {
		protos = []string{"h2", "http/1.1"}
	}
	cert := selfSigned()
	srv.TLSConfig = &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   protos,
	}
	fmt.Println("server:", *addr, "TLS", *alpn)
	log.Fatal(srv.ServeTLS(ln, "", ""))
}

// selfSigned makes a one-day P-256 certificate for bench.test and 127.0.0.1.
// Clients skip chain verification; the names still have to match.
func selfSigned() tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "bench.test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"bench.test"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		log.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		log.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		log.Fatal(err)
	}
	return cert
}
