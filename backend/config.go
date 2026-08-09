package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// Config holds the backend's runtime configuration, sourced from the
// process environment (optionally seeded from a local .env file).
type Config struct {
	OpenAIAPIKey    string
	AnthropicAPIKey string
	Addr            string // host:port the HTTP server binds to
}

// loadEnvFile reads simple KEY=VALUE lines from path into the process
// environment, skipping blank lines and lines starting with '#'. Existing
// environment variables are never overwritten, so real env vars (e.g. set
// by a process manager) always take precedence over the .env file.
// It is not an error for the file to be missing.
func loadEnvFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		if key == "" {
			continue
		}
		if _, exists := os.LookupEnv(key); !exists {
			os.Setenv(key, value)
		}
	}
	return scanner.Err()
}

// loadConfig loads .env (if present) and reads the required API keys from
// the environment. It returns an error naming every missing key so the
// server fails fast at startup rather than on the first /api/v1/dictate
// request.
func loadConfig() (Config, error) {
	_ = loadEnvFile(".env")

	cfg := Config{
		OpenAIAPIKey:    os.Getenv("OPENAI_API_KEY"),
		AnthropicAPIKey: os.Getenv("ANTHROPIC_API_KEY"),
		Addr:            "127.0.0.1:8080",
	}

	var missing []string
	if cfg.OpenAIAPIKey == "" {
		missing = append(missing, "OPENAI_API_KEY")
	}
	if cfg.AnthropicAPIKey == "" {
		missing = append(missing, "ANTHROPIC_API_KEY")
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variable(s): %s (copy .env.example to .env and fill them in)", strings.Join(missing, ", "))
	}

	return cfg, nil
}
