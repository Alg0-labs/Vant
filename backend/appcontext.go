package main

import "strings"

// AppContext is the kind of writing surface the dictated text is destined
// for. It selects which cleanup prompt Claude receives.
type AppContext string

const (
	ContextAIAssistant AppContext = "ai_assistant"
	ContextEmail       AppContext = "email"
	ContextCode        AppContext = "code"
	ContextMessaging   AppContext = "messaging"
	ContextWriting     AppContext = "writing"
	ContextGeneric     AppContext = "generic"
)

// FocusInfo describes the application that had keyboard focus when the
// dictation was recorded. WindowTitle is best-effort — it's empty unless
// the client could read it via the Accessibility API.
type FocusInfo struct {
	BundleID    string
	AppName     string
	WindowTitle string
}

// bundlePrefixes maps a bundle-ID prefix to a context. Prefix matching
// covers vendors that ship many bundle IDs from one family (JetBrains
// IDEs, Microsoft Office, Apple iWork).
var bundlePrefixes = map[string]AppContext{
	"com.jetbrains.":     ContextCode,
	"com.apple.iWork.":   ContextWriting,
	"com.sublimetext.":   ContextCode,
	"com.googlecode.ite": ContextCode, // iTerm2
}

// bundleIDs maps an exact bundle identifier to a context.
var bundleIDs = map[string]AppContext{
	// AI assistants
	"com.anthropic.claudefordesktop": ContextAIAssistant,
	"com.openai.chat":                ContextAIAssistant,

	// Terminals, IDEs, coding tools
	"com.apple.Terminal":              ContextCode,
	"com.googlecode.iterm2":           ContextCode,
	"dev.warp.Warp-Stable":            ContextCode,
	"com.mitchellh.ghostty":           ContextCode,
	"org.alacritty":                   ContextCode,
	"net.kovidgoyal.kitty":            ContextCode,
	"com.microsoft.VSCode":            ContextCode,
	"com.visualstudio.code.oss":       ContextCode,
	"com.apple.dt.Xcode":              ContextCode,
	"dev.zed.Zed":                     ContextCode,
	"com.todesktop.230313mzl4w4u92":   ContextCode, // Cursor
	"com.googlecode.iterm2.iTermTask": ContextCode,

	// Email
	"com.apple.mail":             ContextEmail,
	"com.microsoft.Outlook":      ContextEmail,
	"com.readdle.smartemail-Mac": ContextEmail, // Spark
	"it.bloop.airmail2":          ContextEmail,
	"com.superhuman.electron":    ContextEmail,
	"com.CocoaPods.MailMate":     ContextEmail,
	"com.freron.MailMate":        ContextEmail,
	"com.postbox-inc.postbox":    ContextEmail,
	"org.mozilla.thunderbird":    ContextEmail,
	"com.apple.MailServiceAgent": ContextEmail,

	// Messaging
	"com.tinyspeck.slackmacgap":         ContextMessaging,
	"com.microsoft.teams":               ContextMessaging,
	"com.microsoft.teams2":              ContextMessaging,
	"com.hnc.Discord":                   ContextMessaging,
	"com.apple.MobileSMS":               ContextMessaging,
	"ru.keepcoder.Telegram":             ContextMessaging,
	"com.tdesktop.Telegram":             ContextMessaging,
	"org.whispersystems.signal-desktop": ContextMessaging,
	"net.whatsapp.WhatsApp":             ContextMessaging,
	"desktop.WhatsApp":                  ContextMessaging,
	"com.facebook.archon":               ContextMessaging, // Messenger

	// Documents and writing
	"com.apple.TextEdit":                ContextWriting,
	"com.apple.Notes":                   ContextWriting,
	"com.microsoft.Word":                ContextWriting,
	"notion.id":                         ContextWriting,
	"md.obsidian":                       ContextWriting,
	"net.shinyfrog.bear":                ContextWriting,
	"com.lukilabs.lukiapp":              ContextWriting, // Craft
	"com.literatureandlatte.scrivener3": ContextWriting,
	"com.ulyssesapp.mac":                ContextWriting,
	"pro.writer.mac":                    ContextWriting,
	"com.google.Chrome.app.Docs":        ContextWriting,
}

// browserBundleIDs are apps whose bundle ID says nothing about what the
// user is actually typing into — the window title is the only available
// signal, so these fall through to title-based classification.
var browserBundleIDs = map[string]bool{
	"com.apple.Safari":                  true,
	"com.google.Chrome":                 true,
	"com.google.Chrome.beta":            true,
	"com.google.Chrome.canary":          true,
	"org.mozilla.firefox":               true,
	"com.microsoft.edgemac":             true,
	"com.brave.Browser":                 true,
	"com.operasoftware.Opera":           true,
	"company.thebrowser.Browser":        true, // Arc
	"company.thebrowser.dia":            true, // Dia
	"com.vivaldi.Vivaldi":               true,
	"com.apple.SafariTechnologyPreview": true,
}

// titleHints maps a lowercased substring of a window title to a context,
// used to disambiguate browsers (and as a last resort for unknown apps).
// Order matters: the first match in titleHintOrder wins.
var titleHints = map[string]AppContext{
	"gmail":           ContextEmail,
	"outlook":         ContextEmail,
	"proton mail":     ContextEmail,
	"fastmail":        ContextEmail,
	"zoho mail":       ContextEmail,
	"claude":          ContextAIAssistant,
	"chatgpt":         ContextAIAssistant,
	"gemini":          ContextAIAssistant,
	"perplexity":      ContextAIAssistant,
	"copilot":         ContextAIAssistant,
	"slack":           ContextMessaging,
	"discord":         ContextMessaging,
	"microsoft teams": ContextMessaging,
	"whatsapp":        ContextMessaging,
	"telegram":        ContextMessaging,
	"github":          ContextCode,
	"gitlab":          ContextCode,
	"stack overflow":  ContextCode,
	"codepen":         ContextCode,
	"replit":          ContextCode,
	"google docs":     ContextWriting,
	"notion":          ContextWriting,
	"overleaf":        ContextWriting,
	"confluence":      ContextWriting,
	"linear":          ContextWriting,
	"jira":            ContextWriting,
	"medium":          ContextWriting,
	"substack":        ContextWriting,
}

// titleHintOrder fixes the precedence of titleHints, since Go map
// iteration order is randomized and a title like "Slack | GitHub" would
// otherwise classify nondeterministically.
var titleHintOrder = []string{
	"gmail", "outlook", "proton mail", "fastmail", "zoho mail",
	"claude", "chatgpt", "gemini", "perplexity", "copilot",
	"slack", "discord", "microsoft teams", "whatsapp", "telegram",
	"github", "gitlab", "stack overflow", "codepen", "replit",
	"google docs", "overleaf", "confluence", "notion", "linear", "jira",
	"medium", "substack",
}

// Classify determines which writing surface the dictation is headed for.
func (f FocusInfo) Classify() AppContext {
	if ctx, ok := bundleIDs[f.BundleID]; ok {
		return ctx
	}
	for prefix, ctx := range bundlePrefixes {
		if strings.HasPrefix(f.BundleID, prefix) {
			return ctx
		}
	}

	// Browsers carry no useful signal in the bundle ID; the window title
	// (e.g. "Inbox (12) - you@gmail.com - Gmail") is all we have.
	if browserBundleIDs[f.BundleID] {
		if ctx, ok := classifyByTitle(f.WindowTitle); ok {
			return ctx
		}
		return ContextGeneric
	}

	// Unknown app: try the title, then the app's own name, before giving
	// up. Catches Electron wrappers and apps not in the tables above.
	if ctx, ok := classifyByTitle(f.WindowTitle); ok {
		return ctx
	}
	if ctx, ok := classifyByTitle(f.AppName); ok {
		return ctx
	}
	return ContextGeneric
}

func classifyByTitle(title string) (AppContext, bool) {
	lower := strings.ToLower(title)
	if lower == "" {
		return "", false
	}
	for _, hint := range titleHintOrder {
		if strings.Contains(lower, hint) {
			return titleHints[hint], true
		}
	}
	return "", false
}

const basePrompt = `You are a dictation post-processor. You receive a raw voice transcript and return text that will be pasted directly into the application described below, so your reply must be ready to paste with no further editing.

Always:
- Remove filler words (um, uh, like, so, you know), false starts, repetitions, and stutters.
- Fix spelling, grammar, wording, punctuation, structure, and formatting.
- Preserve the speaker's meaning and intent. Never invent facts, names, numbers, or requirements that were not dictated.
- If the application context and the dictated text conflict, follow the clear intent of the text.
- If the intent is ambiguous, make the smallest reasonable correction rather than inventing information.
- Reply with only the finished text. No preamble, no commentary, no explanation of what you changed, no surrounding quotation marks.`

var contextInstructions = map[AppContext]string{
	ContextAIAssistant: `The text is going into an AI assistant, so rewrite it as a prompt: clear, specific, well-structured, and easy for a model to follow. State the task and any constraints explicitly, and break multi-part requests into readable structure. Do not answer the prompt yourself, and do not add requirements the speaker did not express.`,

	ContextEmail: `The text is going into an email client, so format it as a proper email: an appropriate subject line, greeting, body, and closing where each is warranted. Default to a professional but natural tone. If the dictation is clearly just a reply or a fragment of a body, format only that rather than inventing a full email around it.`,

	ContextCode: `The text is going into a terminal, IDE, or other coding tool, so treat it as a technical request, command, or code. Fix syntax and formatting, use exact technical terms with correct casing for commands, flags, paths, and identifiers, and make the intended action clear. If it is a shell command, reply with the command itself and nothing around it.`,

	ContextMessaging: `The text is going into a chat app, so write it as a natural, concise chat message suited to that platform. Keep it conversational rather than formal: no subject line, no formal greeting, no sign-off.`,

	ContextWriting: `The text is going into a document or writing app, so improve grammar, clarity, formatting, and overall structure while preserving the author's voice. Use paragraph breaks where the content shifts, and lists only where the content genuinely is a list.`,

	ContextGeneric: `The application in focus is general-purpose or unknown, so clean the text into clear, well-punctuated prose without imposing any particular document format.`,
}

// SystemPromptFor builds the Claude system prompt for the app that had
// focus when the dictation was captured.
func SystemPromptFor(f FocusInfo) (string, AppContext) {
	appCtx := f.Classify()

	var b strings.Builder
	b.WriteString(basePrompt)
	b.WriteString("\n\n")
	b.WriteString(contextInstructions[appCtx])

	if descriptor := f.describe(); descriptor != "" {
		b.WriteString("\n\nApplication in focus: ")
		b.WriteString(descriptor)
	}

	return b.String(), appCtx
}

// describe renders a short human-readable identifier for the focused app,
// so the model has the concrete app name and not just the category.
func (f FocusInfo) describe() string {
	name := strings.TrimSpace(f.AppName)
	title := strings.TrimSpace(f.WindowTitle)

	switch {
	case name != "" && title != "":
		return name + " — window titled " + title
	case name != "":
		return name
	case title != "":
		return title
	default:
		return ""
	}
}
