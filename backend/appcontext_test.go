package main

import (
	"strings"
	"testing"
)

func TestClassify(t *testing.T) {
	tests := []struct {
		name  string
		focus FocusInfo
		want  AppContext
	}{
		{
			name:  "exact bundle id — terminal",
			focus: FocusInfo{BundleID: "com.apple.Terminal", AppName: "Terminal"},
			want:  ContextCode,
		},
		{
			name:  "exact bundle id — mail",
			focus: FocusInfo{BundleID: "com.apple.mail", AppName: "Mail"},
			want:  ContextEmail,
		},
		{
			name:  "exact bundle id — slack",
			focus: FocusInfo{BundleID: "com.tinyspeck.slackmacgap", AppName: "Slack"},
			want:  ContextMessaging,
		},
		{
			name:  "exact bundle id — claude desktop",
			focus: FocusInfo{BundleID: "com.anthropic.claudefordesktop", AppName: "Claude"},
			want:  ContextAIAssistant,
		},
		{
			name:  "prefix match — jetbrains ide",
			focus: FocusInfo{BundleID: "com.jetbrains.goland", AppName: "GoLand"},
			want:  ContextCode,
		},
		{
			name:  "prefix match — iWork pages",
			focus: FocusInfo{BundleID: "com.apple.iWork.Pages", AppName: "Pages"},
			want:  ContextWriting,
		},
		{
			name: "browser disambiguated by title — gmail",
			focus: FocusInfo{
				BundleID:    "com.google.Chrome",
				AppName:     "Google Chrome",
				WindowTitle: "Inbox (12) - you@gmail.com - Gmail",
			},
			want: ContextEmail,
		},
		{
			name: "browser disambiguated by title — claude.ai",
			focus: FocusInfo{
				BundleID:    "com.apple.Safari",
				AppName:     "Safari",
				WindowTitle: "Claude",
			},
			want: ContextAIAssistant,
		},
		{
			name: "browser disambiguated by title — github",
			focus: FocusInfo{
				BundleID:    "company.thebrowser.Browser",
				AppName:     "Arc",
				WindowTitle: "anthropics/anthropic-sdk-go: GitHub",
			},
			want: ContextCode,
		},
		{
			name: "browser with unrecognized title falls back to generic",
			focus: FocusInfo{
				BundleID:    "com.google.Chrome",
				AppName:     "Google Chrome",
				WindowTitle: "Some Random Blog Post",
			},
			want: ContextGeneric,
		},
		{
			name: "unknown app recognized via window title",
			focus: FocusInfo{
				BundleID:    "com.unknown.someapp",
				AppName:     "SomeApp",
				WindowTitle: "Notion — Roadmap",
			},
			want: ContextWriting,
		},
		{
			name:  "unknown app recognized via app name",
			focus: FocusInfo{BundleID: "com.unknown.wrapper", AppName: "Telegram Desktop"},
			want:  ContextMessaging,
		},
		{
			name:  "completely unknown falls back to generic",
			focus: FocusInfo{BundleID: "com.unknown.thing", AppName: "Thing"},
			want:  ContextGeneric,
		},
		{
			name:  "empty focus info falls back to generic",
			focus: FocusInfo{},
			want:  ContextGeneric,
		},
		{
			name: "exact bundle id wins over a conflicting window title",
			focus: FocusInfo{
				BundleID:    "com.apple.Terminal",
				AppName:     "Terminal",
				WindowTitle: "gmail — man page",
			},
			want: ContextCode,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.focus.Classify(); got != tt.want {
				t.Errorf("Classify() = %q, want %q", got, tt.want)
			}
		})
	}
}

// Title hints are matched in a fixed order because Go map iteration is
// randomized; a title containing two hints must classify deterministically.
func TestClassifyByTitleIsDeterministic(t *testing.T) {
	focus := FocusInfo{
		BundleID:    "com.google.Chrome",
		WindowTitle: "Slack | GitHub | Gmail",
	}
	first := focus.Classify()
	for i := 0; i < 100; i++ {
		if got := focus.Classify(); got != first {
			t.Fatalf("Classify() is nondeterministic: got %q then %q", first, got)
		}
	}
}

func TestSystemPromptFor(t *testing.T) {
	t.Run("includes the context-specific instruction", func(t *testing.T) {
		prompt, appCtx := SystemPromptFor(FocusInfo{
			BundleID: "com.apple.mail",
			AppName:  "Mail",
		})
		if appCtx != ContextEmail {
			t.Fatalf("context = %q, want %q", appCtx, ContextEmail)
		}
		if !strings.Contains(prompt, "email client") {
			t.Errorf("prompt missing email instruction:\n%s", prompt)
		}
		if !strings.Contains(prompt, "Remove filler words") {
			t.Errorf("prompt missing shared base rules:\n%s", prompt)
		}
	})

	t.Run("names the focused app", func(t *testing.T) {
		prompt, _ := SystemPromptFor(FocusInfo{
			BundleID:    "com.tinyspeck.slackmacgap",
			AppName:     "Slack",
			WindowTitle: "#engineering",
		})
		if !strings.Contains(prompt, "Slack") || !strings.Contains(prompt, "#engineering") {
			t.Errorf("prompt missing app descriptor:\n%s", prompt)
		}
	})

	t.Run("every context has an instruction", func(t *testing.T) {
		all := []AppContext{
			ContextAIAssistant, ContextEmail, ContextCode,
			ContextMessaging, ContextWriting, ContextGeneric,
		}
		for _, c := range all {
			if contextInstructions[c] == "" {
				t.Errorf("context %q has no instruction text", c)
			}
		}
	})
}
