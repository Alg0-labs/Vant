package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const (
	claudeModel      = anthropic.ModelClaudeSonnet5
	claudeMaxTokens  = 1024
	claudeRequestTTL = 30 * time.Second
)

// ClaudeClient sends raw transcripts to the Anthropic Messages API for
// filler-word removal and grammar cleanup.
type ClaudeClient struct {
	client anthropic.Client
}

// NewClaudeClient builds a ClaudeClient authenticated with apiKey. Every
// call made through it is bounded by claudeRequestTTL.
func NewClaudeClient(apiKey string) *ClaudeClient {
	return &ClaudeClient{
		client: anthropic.NewClient(
			option.WithAPIKey(apiKey),
			option.WithHTTPClient(&http.Client{Timeout: claudeRequestTTL}),
		),
	}
}

// Cleanup rewrites rawTranscript for the application that had focus when
// it was dictated: an email client gets an email, a terminal gets a
// command, an AI assistant gets a well-formed prompt. An empty input is
// returned unchanged without calling the API.
//
// It returns the cleaned text along with the context the focused app was
// classified into, so callers can log which prompt was applied.
func (c *ClaudeClient) Cleanup(ctx context.Context, rawTranscript string, focus FocusInfo) (string, AppContext, error) {
	systemPrompt, appCtx := SystemPromptFor(focus)

	if strings.TrimSpace(rawTranscript) == "" {
		return "", appCtx, nil
	}

	ctx, cancel := context.WithTimeout(ctx, claudeRequestTTL)
	defer cancel()

	resp, err := c.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     claudeModel,
		MaxTokens: claudeMaxTokens,
		System: []anthropic.TextBlockParam{
			{Text: systemPrompt},
		},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(rawTranscript)),
		},
	})
	if err != nil {
		return "", appCtx, fmt.Errorf("claude cleanup request failed: %w", err)
	}

	if resp.StopReason == anthropic.StopReasonRefusal {
		return "", appCtx, fmt.Errorf("claude declined to process the transcript (%s)", resp.StopDetails.Category)
	}

	for _, block := range resp.Content {
		if text, ok := block.AsAny().(anthropic.TextBlock); ok {
			return strings.TrimSpace(text.Text), appCtx, nil
		}
	}

	return "", appCtx, errors.New("claude response contained no text content")
}
