package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
)

// maxUploadBytes caps the incoming multipart body. Whisper itself rejects
// files over 25 MB, so there's no reason to accept more on the way in.
const maxUploadBytes = 25 << 20 // 25 MB

// Multipart field names the client uploads under. These must match the
// constants in BackendClient.swift.
const (
	audioFormField        = "audio"
	focusBundleIDField    = "app_bundle_id"
	focusAppNameField     = "app_name"
	focusWindowTitleField = "window_title"
)

type dictateResponse struct {
	Text string `json:"text"`
}

type errorResponse struct {
	Error string `json:"error"`
}

// Server wires the upstream clients used by the HTTP handlers.
type Server struct {
	whisper *WhisperClient
	claude  *ClaudeClient
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writing response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}

// handleDictate implements POST /api/v1/dictate: accept a multipart audio
// upload, transcribe it with Whisper, clean the transcript with Claude, and
// return the result as {"text": "..."}.
func (s *Server) handleDictate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "only POST is supported")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	if err := r.ParseMultipartForm(maxUploadBytes); err != nil {
		writeError(w, http.StatusBadRequest, "invalid multipart upload: "+err.Error())
		return
	}

	file, header, err := r.FormFile(audioFormField)
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing \""+audioFormField+"\" file field")
		return
	}
	defer file.Close()

	log.Printf("[dictate] received upload: filename=%q size=%d bytes content-type=%q",
		header.Filename, header.Size, header.Header.Get("Content-Type"))

	focus := FocusInfo{
		BundleID:    r.FormValue(focusBundleIDField),
		AppName:     r.FormValue(focusAppNameField),
		WindowTitle: r.FormValue(focusWindowTitleField),
	}
	log.Printf("[focus] app=%q bundle=%q window=%q",
		focus.AppName, focus.BundleID, focus.WindowTitle)

	ctx := r.Context()

	rawTranscript, err := s.whisper.Transcribe(ctx, file, header.Filename)
	if err != nil {
		log.Printf("whisper transcription failed: %v", err)
		writeError(w, statusForUpstreamError(ctx, err), "transcription failed: "+err.Error())
		return
	}
	log.Printf("[whisper] raw transcript (%d chars):\n%s", len(rawTranscript), rawTranscript)

	cleanText, appCtx, err := s.claude.Cleanup(ctx, rawTranscript, focus)
	if err != nil {
		log.Printf("claude cleanup failed: %v", err)
		writeError(w, statusForUpstreamError(ctx, err), "cleanup failed: "+err.Error())
		return
	}
	log.Printf("[claude] context=%s cleaned text (%d chars):\n%s", appCtx, len(cleanText), cleanText)

	writeJSON(w, http.StatusOK, dictateResponse{Text: cleanText})
}

// statusForUpstreamError maps a failure from either upstream API to an HTTP
// status: 504 when the request context deadline was the cause, 502
// (bad gateway) for every other upstream failure.
func statusForUpstreamError(ctx context.Context, err error) int {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		return http.StatusGatewayTimeout
	}
	return http.StatusBadGateway
}
