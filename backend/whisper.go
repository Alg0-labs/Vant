package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"time"
)

const (
	whisperEndpoint   = "https://api.openai.com/v1/audio/transcriptions"
	whisperModel      = "whisper-1"
	whisperRequestTTL = 60 * time.Second
)

// WhisperClient transcribes audio via the OpenAI Whisper API.
type WhisperClient struct {
	apiKey     string
	httpClient *http.Client
}

// NewWhisperClient builds a WhisperClient authenticated with apiKey. Every
// call made through it is bounded by whisperRequestTTL.
func NewWhisperClient(apiKey string) *WhisperClient {
	return &WhisperClient{
		apiKey:     apiKey,
		httpClient: &http.Client{Timeout: whisperRequestTTL},
	}
}

type whisperResponse struct {
	Text string `json:"text"`
}

type whisperErrorResponse struct {
	Error struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Transcribe uploads the audio in r (named filename, e.g. "dictation.m4a")
// to Whisper and returns the raw transcript text.
func (w *WhisperClient) Transcribe(ctx context.Context, r io.Reader, filename string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, whisperRequestTTL)
	defer cancel()

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)

	part, err := mw.CreateFormFile("file", filename)
	if err != nil {
		return "", fmt.Errorf("building whisper request: %w", err)
	}
	if _, err := io.Copy(part, r); err != nil {
		return "", fmt.Errorf("reading audio for whisper: %w", err)
	}
	if err := mw.WriteField("model", whisperModel); err != nil {
		return "", fmt.Errorf("building whisper request: %w", err)
	}
	if err := mw.Close(); err != nil {
		return "", fmt.Errorf("building whisper request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, whisperEndpoint, &body)
	if err != nil {
		return "", fmt.Errorf("creating whisper request: %w", err)
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+w.apiKey)

	resp, err := w.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("calling whisper: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading whisper response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var errResp whisperErrorResponse
		if json.Unmarshal(respBody, &errResp) == nil && errResp.Error.Message != "" {
			return "", fmt.Errorf("whisper returned %d: %s", resp.StatusCode, errResp.Error.Message)
		}
		return "", fmt.Errorf("whisper returned %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var result whisperResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", fmt.Errorf("parsing whisper response: %w", err)
	}

	return result.Text, nil
}
