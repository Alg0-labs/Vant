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

	httpServer := &http.Server{
		// Binding to 127.0.0.1 (never 0.0.0.0) keeps the server off the
		// LAN — only processes on this machine can reach it.
		Addr:         cfg.Addr,
		Handler:      newRouter(server),
		ReadTimeout:  65 * time.Second,
		WriteTimeout: 65 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("LocalFlow backend listening on http://%s%s/dictate", cfg.Addr, apiV1Prefix)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
