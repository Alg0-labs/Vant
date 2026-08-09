package main

import (
	"log"
	"net/http"
	"time"
)

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	server := &Server{
		whisper: NewWhisperClient(cfg.OpenAIAPIKey),
		claude:  NewClaudeClient(cfg.AnthropicAPIKey),
	}

	// WriteTimeout spans the whole handler, so it has to exceed the worst
	// case of both upstream calls run back to back — otherwise a slow but
	// otherwise successful dictation has its connection killed mid-flight.
	// Derived from the upstream budgets so the two can't drift apart.
	writeTimeout := whisperRequestTTL + claudeRequestTTL + 30*time.Second

	httpServer := &http.Server{
		// Binding to 127.0.0.1 (never 0.0.0.0) keeps the server off the
		// LAN — only processes on this machine can reach it.
		Addr:         cfg.Addr,
		Handler:      newRouter(server),
		ReadTimeout:  65 * time.Second,
		WriteTimeout: writeTimeout,
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("Vant backend listening on http://%s%s/dictate", cfg.Addr, apiV1Prefix)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
