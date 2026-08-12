package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const (
	claudeMaxTokens  = 1024
	claudeRequestTTL = 30 * time.Second
)

// defaultClaudeModel is Haiku 4.5 because dictation cleanup is latency
// critical and mechanically simple: strip fillers, punctuate, reshape to
// fit the target app. Haiku is the fastest model and handles this well.
// Override with ANTHROPIC_MODEL (e.g. claude-sonnet-5) to trade latency
// for more polished long-form reformatting.
const defaultClaudeModel = anthropic.ModelClaudeHaiku4_5

// effortCapableModels are models that accept output_config.effort. Sending
// it to a model that doesn't support it (Haiku 4.5, Sonnet 4.5) is a 400,
// so it's gated rather than sent unconditionally.
var effortCapableModels = map[anthropic.Model]bool{
	anthropic.ModelClaudeSonnet5: true,
	"claude-opus-5":              true,
	anthropic.ModelClaudeOpus4_8: true,
	anthropic.ModelClaudeOpus4_7: true,
}

// ClaudeClient sends raw transcripts to the Anthropic Messages API for
// filler-word removal and context-appropriate reformatting.
type ClaudeClient struct {
	client anthropic.Client
	model  anthropic.Model
}

// NewClaudeClient builds a ClaudeClient authenticated with apiKey. An
// empty model falls back to defaultClaudeModel. Every call is bounded by
// claudeRequestTTL.
func NewClaudeClient(apiKey string, model string) *ClaudeClient {
	selected := defaultClaudeModel
	if strings.TrimSpace(model) != "" {
		selected = anthropic.Model(strings.TrimSpace(model))
	}

	return &ClaudeClient{
		client: anthropic.NewClient(
			option.WithAPIKey(apiKey),
			option.WithHTTPClient(&http.Client{
				Timeout:   claudeRequestTTL,
				Transport: sharedTransport(),
			}),
		),
		model: selected,
	}
}

func (c *ClaudeClient) Model() anthropic.Model { return c.model }

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

	params := anthropic.MessageNewParams{
		Model:     c.model,
		MaxTokens: claudeMaxTokens,
		System: []anthropic.TextBlockParam{
			{Text: systemPrompt},
		},
		// Delimited so the transcript is unambiguously data. Without this,
		// dictation phrased as a question ("what was on my calendar
		// yesterday") reads as a question addressed to the model, and it
		// answers instead of rewriting.
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(
				"<transcript>" + rawTranscript + "</transcript>",
			)),
		},
		// Thinking is explicitly OFF. This is the single largest latency
		// win in the pipeline: Sonnet 5 and later run adaptive thinking at
		// high effort by *default*, which added ~2s to every dictation for
		// a task that needs no reasoning. Cleanup is a rewrite, not a
		// problem to solve.
		Thinking: anthropic.ThinkingConfigParamUnion{
			OfDisabled: &anthropic.ThinkingConfigDisabledParam{},
		},
	}

	// Lowest effort, on models that accept the parameter at all.
	if effortCapableModels[c.model] {
		params.OutputConfig = anthropic.OutputConfigParam{
			Effort: anthropic.OutputConfigEffortLow,
		}
	}

	resp, err := c.client.Messages.New(ctx, params)
	if err != nil {
		return "", appCtx, fmt.Errorf("claude cleanup request failed: %w", err)
	}

	if resp.StopReason == anthropic.StopReasonRefusal {
		return "", appCtx, fmt.Errorf("claude declined to process the transcript (%s)", resp.StopDetails.Category)
	}

	for _, block := range resp.Content {
		if text, ok := block.AsAny().(anthropic.TextBlock); ok {
			rewrite := strings.TrimSpace(text.Text)

			// Safety net: if the model answered the dictation instead of
			// rewriting it, paste the raw transcript rather than a reply
			// the user never intended to type. Slightly unpolished text is
			// a far better failure than "I don't have access to your
			// calendar" landing in their message.
			if LooksLikeModelBrokeCharacter(rawTranscript, rewrite, appCtx) {
				log.Printf("[guard] discarding rewrite (%d chars from %d-char transcript, context=%s); pasting raw transcript instead:\n%s",
					len(rewrite), len(rawTranscript), appCtx, rewrite)
				return strings.TrimSpace(rawTranscript), appCtx, nil
			}

			return rewrite, appCtx, nil
		}
	}

	return "", appCtx, errors.New("claude response contained no text content")
}
