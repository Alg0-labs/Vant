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
	claudeModel       = anthropic.ModelClaudeSonnet5
	claudeMaxTokens   = 1024
	claudeRequestTTL  = 30 * time.Second
	claudeSystemPrompt = "You clean up raw voice-dictation transcripts for insertion directly into whatever the user is typing. " +
		"Remove filler words (um, uh, like, so, you know), false starts, and stutters. " +
		"Fix grammar, capitalization, and punctuation. Preserve the speaker's meaning, tone, and intent exactly — " +
		"do not summarize, add information, or change the wording beyond what cleanup requires. " +
		"Respond with only the cleaned text and nothing else: no preamble, no quotation marks, no explanation."
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

// Cleanup rewrites rawTranscript into clean, punctuated prose. An empty
// input is returned unchanged without calling the API.
func (c *ClaudeClient) Cleanup(ctx context.Context, rawTranscript string) (string, error) {
	if strings.TrimSpace(rawTranscript) == "" {
		return "", nil
	}

	ctx, cancel := context.WithTimeout(ctx, claudeRequestTTL)
	defer cancel()

	resp, err := c.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     claudeModel,
		MaxTokens: claudeMaxTokens,
		System: []anthropic.TextBlockParam{
			{Text: claudeSystemPrompt},
		},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(rawTranscript)),
		},
	})
	if err != nil {
		return "", fmt.Errorf("claude cleanup request failed: %w", err)
	}

	if resp.StopReason == anthropic.StopReasonRefusal {
		return "", fmt.Errorf("claude declined to process the transcript (%s)", resp.StopDetails.Category)
	}

	for _, block := range resp.Content {
		if text, ok := block.AsAny().(anthropic.TextBlock); ok {
			return strings.TrimSpace(text.Text), nil
		}
	}

	return "", errors.New("claude response contained no text content")
}
