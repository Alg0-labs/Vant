# LocalFlowDictation

A local, open-source Wispr Flow alternative for macOS. Hold `⌃ + Space`, speak, let go — your speech is transcribed, cleaned up, and typed into whatever app has focus. Everything routes through a backend that runs on your own machine; the only network calls are to OpenAI (transcription) and Anthropic (cleanup).

See [`PLAN.md`](./PLAN.md) for the full architecture writeup.

## Layout

```
backend/    Go server — POST /api/v1/dictate (Whisper → Claude pipeline)
client/     Swift menu-bar app — hotkey, recording, paste injection
scripts/    run-backend.sh, build-client.sh
```

## Prerequisites

- macOS 13+
- Go 1.21+ (`brew install go`)
- Xcode 15+ / Swift 5.10+ command line tools
- An [OpenAI API key](https://platform.openai.com/account/api-keys) and an [Anthropic API key](https://console.anthropic.com/)

## Setup

```sh
cp backend/.env.example backend/.env
# edit backend/.env and fill in OPENAI_API_KEY and ANTHROPIC_API_KEY
```

## Running

**1. Start the backend** (binds to `127.0.0.1:8080` only — never exposed on your LAN):

```sh
./scripts/run-backend.sh
```

**2. Build and launch the client:**

```sh
./scripts/build-client.sh
open client/LocalFlow/LocalFlow.app
```

On first launch, LocalFlow will ask for:

- **Microphone access** — required to record.
- **Accessibility access** (System Settings → Privacy & Security → Accessibility) — required to paste the cleaned text into other apps via a synthetic `⌘V`. macOS won't grant this programmatically; toggle it on manually when prompted.

The app runs as a menu-bar-only icon (no Dock entry). Click it to see status and permission shortcuts.

## Usage

Push-to-talk, not toggle: **hold** `⌃ + Space` to record, **release** it to stop, transcribe, clean up, and paste into whatever app has focus. A small floating indicator appears near the top of the screen while recording ("Recording…", with a **Stop** button as an alternative to releasing the key) and while the transcript is being cleaned up ("Cleaning up…"). It doesn't steal keyboard focus from the app you're dictating into.

Holding the key exactly as long as you're speaking (rather than tap-to-start / tap-to-stop) is deliberate — a toggle makes it easy to tap the hotkey a second time out of habit and clip your own sentence.

### Context-aware formatting

LocalFlow notes which app had focus when you started dictating and adapts the text to it, so the same spoken words come out formatted for where they're going:

| App in focus | What you get |
|---|---|
| Claude, ChatGPT, other AI assistants | A clear, specific, well-structured prompt |
| Gmail, Outlook, Mail, Spark… | A formatted email — subject, greeting, body, closing where warranted |
| Terminal, VS Code, Xcode, JetBrains… | A technical request or command with correct syntax and casing |
| Slack, Teams, Discord, Messages… | A natural, concise chat message |
| Notion, Word, Obsidian, Notes… | Prose with improved grammar, structure, and formatting |
| Anything else | Clean, well-punctuated prose with no format imposed |

For browsers — where the app itself tells you nothing — LocalFlow reads the focused window title (e.g. `Inbox (12) – you@gmail.com – Gmail`) to figure out the surface. That uses the Accessibility permission the app already requires; if the title isn't readable, it falls back to generic cleanup.

The formatting never invents content: if the app's context and what you actually said disagree, your words win, and ambiguous dictation gets the smallest reasonable correction rather than made-up detail.

Classification lives in the backend (`backend/appcontext.go`), so you can add apps or retune prompts by editing that file and restarting the backend — no client rebuild, and therefore no re-granting Accessibility.

> `⌃ + Space` is also macOS's default "Select the previous input source" shortcut. LocalFlow's hotkey normally takes priority, but if input-source switching stops working after installing it, disable that shortcut in System Settings → Keyboard → Keyboard Shortcuts → Input Sources.

## On the Swift project

[`PLAN.md`](./PLAN.md) specifies a `LocalFlow.xcodeproj`. This implementation uses `client/LocalFlow/Package.swift` instead — Xcode 15+ opens a `Package.swift` natively as a full project (build, run, debug, and code signing all work the same way), and it's something that can actually be built and verified without Xcode's GUI project generator. Open `client/LocalFlow/` in Xcode, or use `swift build` / `scripts/build-client.sh` from the terminal.

## Notes

- **API versioning:** every backend route is mounted under `/api/v1` (`routes.go`); the client never hardcodes a bare path — `BackendClient.swift` builds every request from a single `apiV1Base` constant.
- **Code signing and Accessibility:** `scripts/build-client.sh` ad-hoc signs by default, which is fine for local dev but can invalidate a granted Accessibility toggle on rebuild (TCC keys grants to path + signature). For a signature that survives rebuilds, run `CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build-client.sh` with a real development certificate.
- **Privacy:** recordings are written to a temp `.m4a`, uploaded to the local backend, and deleted immediately after the request completes — see `AppState.finishRecording()`.
