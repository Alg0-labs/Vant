# LocalFlowDictation — Phase 1 Architecture Blueprint

A local, open-source Wispr Flow alternative: a Swift/SwiftUI macOS menu-bar client paired with a Go orchestration backend that chains OpenAI Whisper transcription with Claude text cleanup, then types the result into any focused app.

| | |
|---|---|
| **Client** | Swift · SwiftUI · menu bar |
| **Backend** | Go · `127.0.0.1:8080` |
| **Speech** | OpenAI `whisper-1` |
| **Cleanup** | Claude Sonnet 5 (`claude-sonnet-5`) |
| **Status** | Phase 1 complete — awaiting approval for Phase 2 execution |

---

## 1. System Architecture Map

```
┌─────────────────────────────── macOS ────────────────────────────────┐
│                                                                      │
│  ┌──────────────────────┐          ┌───────────────────────────┐     │
│  │  Swift Menu-Bar App  │          │   Go Backend (localhost)  │     │
│  │                      │          │                           │     │
│  │ 1. Carbon hotkey     │  HTTP    │ POST /api/v1/dictate      │     │
│  │    ⌃+Space (hold)    │ ───────▶ │  multipart/form-data      │     │
│  │ 2. AVFoundation rec  │  .m4a    │  (audio file)             │     │
│  │    12kHz mono AAC    │          │      │                    │     │
│  │ 3. Receive clean text│ ◀─────── │      ▼                    │     │
│  │ 4. CGEvent ⌘V inject │  JSON    │ ① OpenAI Whisper API      │     │
│  └──────────────────────┘          │    model=whisper-1        │     │
│                                    │    → raw transcript       │     │
│                                    │      │                    │     │
│                                    │      ▼                    │     │
│                                    │ ② Anthropic Messages API  │     │
│                                    │    POST /v1/messages      │     │
│                                    │    → cleaned text         │     │
│                                    └───────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
```

### Data flow

1. **Capture (client).** This is push-to-talk, not toggle: the client records via `AVAudioRecorder` (AAC, 12,000 Hz, mono) for exactly as long as `⌃ + Space` is held down. A floating on-screen indicator (with a Stop button) shows while recording and while the transcript is being cleaned up. `AudioRecorder` keeps a pre-warmed, already-`prepareToRecord()`'d instance ready at all times, so pressing the key doesn't pay that setup latency and clip the first word.
2. **Transport (client → backend).** The `.m4a` file is POSTed to `http://127.0.0.1:8080/api/v1/dictate` as `multipart/form-data`. The Go server binds strictly to `127.0.0.1` — never `0.0.0.0` — so nothing is exposed on the LAN. Audio leaves the machine only over TLS to the two upstream APIs.
3. **Transcription (backend → OpenAI).** Go streams the file to `https://api.openai.com/v1/audio/transcriptions` with `model=whisper-1` and `Authorization: Bearer $OPENAI_API_KEY`. The response is the raw transcript, fillers included.
4. **Cleanup (backend → Anthropic).** The raw transcript goes to the Anthropic Messages API with a system prompt selected by *where the text is headed*. The client reports the focused app's bundle ID, name, and window title alongside the audio; `appcontext.go` classifies that into one of six contexts (AI assistant, email, code, messaging, writing, generic) and composes the matching prompt. Shared base rules apply in every context: strip fillers and false starts, fix grammar and punctuation, never invent content, prefer the text's clear intent over the app's context when they conflict, and return only the finished text with no preamble.
5. **Return + inject (backend → client).** The backend responds with `{"text": "..."}`. The client backs up the clipboard, writes the text, synthesizes `⌘V` via `CGEvent` into whatever app owns keyboard focus, then restores the clipboard 200 ms later.

### Safety properties

- API keys live only in the Go process environment (`.env`, gitignored). The Swift client holds zero secrets.
- Timeouts: 60 s for Whisper, 30 s for Claude. Errors propagate to the client as JSON and surface as a menu-bar notification — never pasted into the focused app.

> **Note on the 12 kHz spec:** whisper-1 is billed per minute of audio ($0.006/min), not by file size — so 12 kHz reduces upload latency but not cost. Whisper resamples internally to 16 kHz; recording at 16 kHz mono AAC costs the same and transcribes slightly more accurately. The plan keeps 12 kHz as specified — it is a one-line constant to change.

---

## 2. File Blueprint Tree

```
LocalFlowDictation/
├── README.md
├── .gitignore                        # excludes .env, build artifacts
├── backend/
│   ├── go.mod                        # module localflow/backend
│   ├── go.sum
│   ├── .env.example                  # OPENAI_API_KEY=, ANTHROPIC_API_KEY=
│   ├── main.go                       # HTTP server, binds 127.0.0.1:8080, routes
│   ├── routes.go                     # /api/v1 router group + version prefix
│   ├── handlers.go                   # POST /api/v1/dictate: multipart parse → pipeline
│   ├── whisper.go                    # OpenAI transcription client (multipart upload)
│   ├── appcontext.go                 # focused-app → context classification + per-context prompts
│   ├── appcontext_test.go            # table tests for classification and prompt assembly
│   ├── claude.go                     # Anthropic Messages API client (context-aware cleanup)
│   └── config.go                     # env loading, key validation at startup
├── client/
│   └── LocalFlow/
│       ├── LocalFlow.xcodeproj
│       └── LocalFlow/
│           ├── LocalFlowApp.swift        # @main, MenuBarExtra scene
│           ├── Info.plist                # NSMicrophoneUsageDescription, LSUIElement=YES
│           ├── LocalFlow.entitlements    # audio-input; sandbox OFF (needed for CGEvent)
│           ├── AppState.swift            # ObservableObject: idle/recording/processing
│           ├── HotkeyManager.swift       # Carbon RegisterEventHotKey, press+release for ⌃+Space
│           ├── FocusContext.swift        # frontmost app bundle ID/name + AX window title
│           ├── RecordingIndicatorWindow.swift  # floating panel: recording/processing state + Stop button
│           ├── AudioRecorder.swift       # AVAudioRecorder, 12kHz mono AAC → temp .m4a
│           ├── BackendClient.swift       # URLSession multipart POST to :8080/api/v1/dictate
│           ├── TextInjector.swift        # clipboard backup → paste → restore (CGEvent)
│           ├── PermissionsManager.swift  # mic + AXIsProcessTrustedWithOptions checks
│           └── MenuBarView.swift         # SwiftUI status view (mic icon states)
└── scripts/
    ├── run-backend.sh                # loads .env, go run ./backend
    └── build-client.sh               # xcodebuild release build
```

### Key structural decisions

- **All backend routes are versioned under `/api/v1`** — `POST /api/v1/dictate` is the only endpoint in this phase. `routes.go` mounts a dedicated router group with the `/api/v1` prefix rather than registering paths on the root mux, so adding `/api/v2` later (or running v1 and v2 side by side during a breaking change) never touches existing handlers. The Swift client never hardcodes the bare path — `BackendClient.swift` builds requests from a single `apiV1Base = "http://127.0.0.1:8080/api/v1"` constant, so a version bump is a one-line change on both sides.
- **Hotkey via Carbon `RegisterEventHotKey`**, not `NSEvent.addGlobalMonitorForEvents`. The Carbon API is the only sanctioned way to *consume* the keystroke system-wide (so `⌃+Space` doesn't also type a space into the focused app), and it works without Input Monitoring permission. Note: `⌃+Space` is also macOS's default "Select the previous input source" shortcut — `RegisterEventHotKey` normally takes priority, but if input-source switching stops working after installing LocalFlow, disable that shortcut in System Settings → Keyboard → Keyboard Shortcuts → Input Sources.
- **Push-to-talk, via `kEventHotKeyPressed` + `kEventHotKeyReleased`.** Carbon hotkeys expose both a press and a release event kind (not just press, which is the more commonly documented one) — `HotkeyManager` installs a handler for both and calls distinct `onPress`/`onRelease` closures. Recording lasts exactly as long as the key is held; there's no "did my second tap register" ambiguity the way there is with a toggle, which is what caused dictations to get cut off mid-sentence under the original design.
- **Context classification lives on the backend, not the client.** The Swift side only reports raw facts about the focused app (bundle ID, name, window title); `appcontext.go` decides what that means and writes the prompt. Two reasons: prompt tuning and new app mappings ship by restarting the backend rather than rebuilding the client, and — because ad-hoc code signing invalidates TCC grants on every rebuild — that difference is the difference between an edit costing nothing and costing a re-grant of Accessibility.
- **Focus is captured at key-down, not on completion.** By the time the transcript returns the user may have switched apps; the target surface is whatever had focus when they started speaking. LocalFlow itself never becomes frontmost (`.accessory` policy, non-activating indicator panel), so it never shadows the real target.
- **Browsers are classified by window title.** A bundle ID of `com.google.Chrome` says nothing about whether the user is in Gmail, Claude, or Google Docs, so browsers fall through to title matching via the Accessibility API (already required for paste injection). AX reads use a 250 ms messaging timeout so an unresponsive app can't stall the hotkey path.
- **The floating recording indicator is a non-activating `NSPanel`**, not a SwiftUI `Window` scene. A normal window would steal keyboard focus from whatever app the user is dictating into, which breaks both the UX and the CGEvent paste target. `RecordingIndicatorController` observes `AppState.$phase` and shows/hides the panel accordingly.
- **App Sandbox disabled** in entitlements: sandboxed apps cannot post `CGEvent`s to other processes or reliably read Accessibility trust. Acceptable for a locally dev-signed app.
- **`LSUIElement = YES`** so the app is menu-bar-only (no Dock icon), using SwiftUI's `MenuBarExtra`.
- **Anthropic calls via the official Go SDK** (`github.com/anthropics/anthropic-sdk-go`) in `claude.go` — headers, retries with backoff on 429/5xx, and typed errors come for free. Whisper stays a hand-rolled multipart HTTP call; one endpoint doesn't justify a dependency.

---

## 3. macOS Permission Handling

### Microphone (TCC: kTCCServiceMicrophone)

- `Info.plist` must contain `NSMicrophoneUsageDescription` ("LocalFlow records audio only while you hold the dictation hotkey; audio is processed and immediately deleted."). Without this string the app crashes on first capture.
- Request on launch with `AVCaptureDevice.requestAccess(for: .audio)`; check state with `AVCaptureDevice.authorizationStatus(for: .audio)`. If denied, a menu item deep-links to `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.

### Accessibility (TCC: kTCCServiceAccessibility) — required for CGEvent injection

```swift
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
```

- Passing `prompt: true` shows the system dialog and pre-lists the app in **System Settings → Privacy & Security → Accessibility**. The user must flip the toggle manually — Apple does not allow programmatic granting.
- Trust state is not KVO-observable, so `PermissionsManager` polls `AXIsProcessTrusted()` on a 1-second timer while untrusted and badges the menu-bar icon until granted. Injection attempts are refused with a visible notice while untrusted — otherwise `CGEvent.post` silently no-ops and users think dictation "ate" their text.
- **README gotcha:** TCC identifies the binary by path + code signature. Every unsigned rebuild can invalidate the grant — sign with a stable development certificate so the toggle stays sticky.

---

## 4. Clipboard & Token Engineering

### Paste-injection sequence (`TextInjector.swift`)

1. **Backup.** Read `NSPasteboard.general` — capture the current `changeCount` and the string contents. (v1 backs up `.string` only; full multi-type fidelity via `NSPasteboardItem` cloning is a documented v2 item.)
2. **Write.** `pasteboard.clearContents()`, then `setString(cleanText, forType: .string)`.
3. **Settle ~50 ms.** Brief pause so the pasteboard server registers the new contents before the paste event fires.
4. **Synthesize ⌘V.** Create a `CGEventSource(stateID: .hidSystemState)`, build key-down/key-up events for virtual key `0x09` (V) with `.maskCommand` set on `event.flags`, and post to `.cghidEventTap`. This lands in whichever app has keyboard focus — Terminal, Safari, Slack, anything.
5. **Restore after 200 ms.** `DispatchQueue.main.asyncAfter(deadline: .now() + 0.2)` → clear and re-write the backed-up string. 200 ms comfortably exceeds the time the frontmost app needs to service the paste. Edge case: if the user copied something themselves during the window (`changeCount` moved past our write), restoration is skipped rather than clobbering their newer copy.

### Anthropic API validation

| Item | Value | Verdict |
|---|---|---|
| `x-api-key` | your API key | ✅ Correct auth header |
| `anthropic-version` | `2023-06-01` | ✅ Correct — current version string |
| `Content-Type` | `application/json` | ✅ Required |
| Model ID | `claude-3-5-sonnet-latest` | ❌ Retired — returns 404 |

> **`claude-3-5-sonnet-latest` will fail.** Claude 3.5 Sonnet was retired on October 28, 2025 — the ID no longer resolves. The documented drop-in replacement is **`claude-sonnet-5`** (Claude Sonnet 5), adopted in this design: fast and cheap enough for per-utterance cleanup at $3/$15 per MTok (introductory $2/$10 through Aug 31, 2026), and well suited to short-transcript rewriting. If maximum quality per request is preferred, `claude-opus-5` is the current flagship at $5/$25 — a one-constant swap.

Because the backend uses the official Go SDK, headers are handled automatically. The call in `claude.go` becomes roughly:

```go
resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
    Model:     "claude-sonnet-5",
    MaxTokens: 1024,
    System:    []anthropic.TextBlockParam{{Text: cleanupPrompt}},
    Messages:  []anthropic.MessageParam{
        anthropic.NewUserMessage(anthropic.NewTextBlock(rawTranscript)),
    },
})
```

- The response `content` is a block array — extract the first `text`-type block, never index blindly.
- Check `stop_reason` before trusting output.
- The token-economy goal (12 kHz audio "to keep tokens low") actually applies to the Whisper upload path, not Claude — Claude's cost is driven by transcript length, kept minimal with a terse system prompt and `max_tokens: 1024`.

---

*End of Phase 1 planning blueprint. Phase 2 — step-by-step execution — begins only on explicit approval.*
