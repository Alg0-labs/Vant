package main

import (
	"context"
	"crypto/tls"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
)

// Both upstream clients share one transport so they share one connection
// pool: TLS handshakes to api.openai.com and api.anthropic.com are paid
// once and then reused across dictations. A cold handshake costs 100-300ms
// on the critical path, and dictation is bursty enough that the default
// transport's idle timeouts would drop connections between uses.
var (
	transportOnce sync.Once
	transport     *http.Transport
)

func sharedTransport() *http.Transport {
	transportOnce.Do(func() {
		transport = &http.Transport{
			DialContext: (&net.Dialer{
				Timeout:   5 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			// Generous idle settings: keep upstream connections hot
			// between dictations rather than re-handshaking each time.
			MaxIdleConns:        16,
			MaxIdleConnsPerHost: 4,
			IdleConnTimeout:     10 * time.Minute,
			TLSHandshakeTimeout: 5 * time.Second,
			ForceAttemptHTTP2:   true,
		}
	})
	return transport
}

// upstreamHosts are pre-connected at startup and re-warmed periodically.
var upstreamHosts = []string{
	"api.openai.com:443",
	"api.anthropic.com:443",
}

// WarmUpstreamConnections opens and holds a TLS connection to each upstream
// so the first real dictation doesn't pay a handshake, then re-warms on an
// interval to keep the pool populated through idle periods.
//
// This only primes DNS and the TLS session; the actual pooled connections
// belong to sharedTransport() and are established on first request. The
// warm-up makes that first request measurably cheaper.
func WarmUpstreamConnections(ctx context.Context) {
	warm := func() {
		for _, host := range upstreamHosts {
			go func(host string) {
				dialer := &net.Dialer{Timeout: 5 * time.Second}
				conn, err := tls.DialWithDialer(dialer, "tcp", host, nil)
				if err != nil {
					log.Printf("[warmup] %s: %v", host, err)
					return
				}
				conn.Close()
			}(host)
		}
	}

	warm()

	go func() {
		ticker := time.NewTicker(4 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				warm()
			}
		}
	}()
}
