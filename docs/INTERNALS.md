# Vant — Internal Engineering Documentation

Audience: anyone working on Vant's code. This documents how the system actually behaves, why it's built this way, and where the sharp edges are. For setup and day-to-day usage see [`README.md`](../README.md); for the original design blueprint see [`PLAN.md`](../PLAN.md).

---

## 1. What Vant is

Vant is a local, open-source alternative to Wispr Flow for macOS. The user holds `⌃ + Space`, speaks, and releases; a few seconds later the cleaned-up text is typed into whatever application had keyboard focus.

Two things make it more than a thin wrapper around a speech API:

1. **It cleans up dictation.** Raw speech-to-text output is full of `um`, `uh`, false starts, and missing punctuation. Vant runs every transcript through Claude to produce text a person would actually have typed.
2. **It adapts to where the text is going.** The same spoken sentence becomes a structured prompt in Claude, a formatted email in Gmail, a shell command in Terminal, or a casual message in Slack — because Vant knows which app had focus when you started talking.

It is deliberately **local-first**: the orchestration server runs on the user's own machine, bound to loopback. Audio leaves the machine only in the two outbound TLS calls to OpenAI and Anthropic.

### Non-goals

- Not a cloud service. There is no hosted component, no account, no telemetry.
- Not offline. It requires OpenAI and Anthropic API access; on-device transcription is not implemented.
- Not multi-platform. macOS only — the hotkey, permissions, and paste injection are all platform-specific.

---

## 2. System shape

Two processes on one machine:

```
   ┌──────────────────────────────┐        ┌────────────────────────────┐
   │  Vant.app (Swift, menu bar)  │        │  backend (Go, 127.0.0.1)   │
   │                              │        │                            │
   │  HotkeyManager   ⌃Space      │        │  POST /api/v1/dictate      │
   │  FocusContext    who's up?   │  HTTP  │        │                   │
   │  AudioRecorder   mic → .m4a  │ ─────▶ │        ├──▶ OpenAI Whisper │
   │  BackendClient   upload      │        │        │    (transcribe)   │
   │  TextInjector    ⌘V paste    │ ◀───── │        └──▶ Anthropic      │
   │  RecordingIndicator          │  JSON  │             (clean + fit   │
   └──────────────────────────────┘        │              to context)   │
                                           └────────────────────────────┘
```

**Why two processes rather than one Swift app calling both APIs directly?**

- **Secrets stay out of the client.** API keys live only in the backend's environment. The distributed `.app` holds nothing sensitive.
- **Prompt iteration is free.** Every client rebuild is ad-hoc signed, which invalidates the macOS Accessibility grant (see §7). Keeping all prompt and classification logic server-side means tuning behaviour costs a backend restart, not a re-grant.
- **The interesting logic is testable.** Classification and prompt assembly are pure Go functions with table tests; the equivalent inside a GUI app would be far harder to exercise.

---

## 3. Lifecycle of one dictation

Following a single `⌃Space` press end to end. File references are the code that owns each step.

| # | Step | Owner |
|---|---|---|
| 1 | Carbon fires `kEventHotKeyPressed` for `⌃Space`. | `HotkeyManager.swift` |
| 2 | `AppState.hotkeyPressed()` checks phase; ignores repeats while recording/processing. | `AppState.swift` |
| 3 | Microphone + Accessibility permissions verified; missing either aborts into `.error`. | `PermissionsManager.swift` |
| 4 | **Focus snapshot taken** — frontmost app's bundle ID, name, and AX window title. | `FocusContext.swift` |
| 5 | Pre-warmed `AVAudioRecorder` starts. Phase → `.recording`. | `AudioRecorder.swift` |
| 6 | Floating indicator appears (observes `AppState.$phase`). | `RecordingIndicatorWindow.swift` |
| 7 | User releases the key → `kEventHotKeyReleased` → `AppState.hotkeyReleased()`. | `HotkeyManager` / `AppState` |
| 8 | Recorder stops, returns the temp `.m4a`; next recorder is immediately re-armed. Phase → `.processing`. | `AudioRecorder.swift` |
| 9 | Multipart POST to `/api/v1/dictate`: audio + the three focus fields. | `BackendClient.swift` |
| 10 | Backend parses multipart, logs the upload and focus. | `handlers.go` |
| 11 | Audio streamed to OpenAI Whisper → raw transcript. | `whisper.go` |
| 12 | Focus classified into a context; matching system prompt composed. | `appcontext.go` |
| 13 | Transcript + prompt → Anthropic Messages API → cleaned text. | `claude.go` |
| 14 | `{"text": "..."}` returned. | `handlers.go` |
| 15 | Clipboard backed up, text written, `⌘V` synthesized, clipboard restored after 200 ms. | `TextInjector.swift` |
| 16 | Temp `.m4a` deleted. Phase → `.idle`; indicator disappears. | `AppState.swift` |

### Two ordering details that matter

**Focus is captured at step 4, not step 15.** By the time the transcript returns, the user may have switched apps. The target surface is whatever had focus when they *started speaking*.

**Vant never becomes frontmost.** It runs under `.accessory` activation policy (no Dock icon), and the indicator is a non-activating `NSPanel`. If either were untrue, Vant would shadow the real target app in step 4 and steal the keystrokes in step 15.

---

## 4. Component reference

### Backend (`backend/`, Go, module `vant/backend`)

| File | Responsibility |
|---|---|
| `main.go` | Loads config, wires clients, binds the HTTP server to `127.0.0.1:8080`. |
| `config.go` | Reads `.env` (never overriding real env vars) and fails fast at startup if either API key is missing. |
| `routes.go` | Mounts routes under the `/api/v1` prefix. |
| `handlers.go` | `POST /api/v1/dictate` — multipart parsing, pipeline orchestration, error mapping, logging. |
| `whisper.go` | Hand-rolled multipart client for OpenAI `whisper-1`. 60 s budget. |
| `appcontext.go` | Focused-app → context classification and per-context prompt assembly. |
| `appcontext_test.go` | Table tests for classification, determinism, and prompt composition. |
| `claude.go` | Anthropic Messages API client via the official Go SDK. 30 s budget. |

### Client (`client/Vant/`, Swift, SwiftUI)

| File | Responsibility |
|---|---|
| `VantApp.swift` | `@main`, `MenuBarExtra` scene, `AppDelegate` launch wiring. |
| `AppState.swift` | State machine (`idle`/`recording`/`processing`/`error`) and flow orchestration. |
| `HotkeyManager.swift` | Carbon global hotkey, press **and** release. |
| `FocusContext.swift` | Frontmost app identity + AX window title. |
| `AudioRecorder.swift` | AVFoundation capture with a pre-warmed recorder. |
| `BackendClient.swift` | Multipart upload; owns the single `apiV1Base` URL constant. |
| `TextInjector.swift` | Clipboard backup → `⌘V` → restore. |
| `PermissionsManager.swift` | Microphone request; Accessibility trust check and polling. |
| `RecordingIndicatorWindow.swift` | Floating non-activating status panel with Stop button. |
| `MenuBarView.swift` | Menu bar popover: status, permission shortcuts, quit. |

---

## 5. API contract

### `POST /api/v1/dictate`

Everything is versioned under `/api/v1`. The client builds every URL from one constant (`BackendClient.apiV1Base`) and the server mounts one prefix (`routes.go`), so a version bump is a one-line change on each side and v1/v2 can run side by side.

**Request** — `multipart/form-data`, max 25 MB (Whisper's own ceiling; no reason to accept more):

| Field | Required | Notes |
|---|---|---|
| `audio` | yes | The recording. AAC in an `.m4a` container. |
| `app_bundle_id` | no | e.g. `com.tinyspeck.slackmacgap`. |
| `app_name` | no | e.g. `Slack`. |
| `window_title` | no | Best-effort; empty when Accessibility can't read it. |

Omitting all three focus fields is valid and yields generic cleanup.

**Responses:**

| Status | Meaning |
|---|---|
| `200` | `{"text": "..."}` — cleaned text. May be `""` for silent audio. |
| `400` | Malformed multipart or missing `audio` field. |
| `405` | Non-POST method. |
| `502` | An upstream API failed (bad key, upstream 5xx, refusal). |
| `504` | The request deadline was exceeded. |

Errors are `{"error": "..."}`. The client surfaces them as an `.error` phase; **failed text is never pasted**.

---

## 6. Context classification

`appcontext.go` maps the focused app to one of six contexts, each with its own prompt:

`ai_assistant` · `email` · `code` · `messaging` · `writing` · `generic`

### Resolution order

1. **Exact bundle ID** (`bundleIDs`) — highest confidence, wins over everything including a conflicting window title.
2. **Bundle ID prefix** (`bundlePrefixes`) — covers vendor families like `com.jetbrains.*`.
3. **Browser? → window title** (`browserBundleIDs` → `titleHints`). A bundle ID of `com.google.Chrome` says nothing about whether the user is in Gmail, Claude, or Google Docs; the title (`Inbox (12) - you@gmail.com - Gmail`) is the only available signal.
4. **Unknown app → window title, then app name.** Catches Electron wrappers and unlisted apps.
5. **Fallback:** `generic`.

> **Title matching is order-dependent by design.** `titleHintOrder` fixes precedence explicitly because Go randomizes map iteration — without it, a title like `Slack | GitHub | Gmail` would classify differently between runs. There's a test pinning this.

### Prompt structure

Every prompt is `basePrompt` + the context-specific instruction + a descriptor naming the actual app. The base rules hold everywhere and are the safety floor:

- Strip fillers, false starts, repetitions.
- Fix spelling, grammar, punctuation, structure.
- **Never invent** facts, names, numbers, or requirements.
- **The text wins over the context** when they conflict.
- **Smallest reasonable correction** when intent is ambiguous.
- Return only the finished text — it gets pasted verbatim.

### Adding an app

Add one line to `bundleIDs` in `appcontext.go` and restart the backend. No client rebuild, no re-granting Accessibility.

To find an app's bundle ID, dictate into it once and read the backend log:

```
[focus] app="Linear" bundle="com.linear" window="VANT-14 · Internal docs"
```

Or query it directly:

```sh
osascript -e 'id of app "Linear"'
```

---

## 7. Permissions and code signing

Vant needs two TCC permissions, for different reasons:

| Permission | Needed for | Failure mode if missing |
|---|---|---|
| **Microphone** | Recording. | Prompted at launch; recording refuses with a visible error. |
| **Accessibility** | Synthesizing `⌘V` into other apps, *and* reading window titles. | `CGEvent.post` silently no-ops — text vanishes with no error. |

Because a missing Accessibility grant fails *silently*, `AppState.beginRecording()` refuses to start rather than letting the user dictate into a void. Trust state isn't KVO-observable, so `PermissionsManager` polls `AXIsProcessTrusted()` once a second while untrusted.

### The ad-hoc signing trap

**This is the single most common source of confusion when developing Vant.**

macOS keys TCC grants to the binary's path *and code signature*. `scripts/build-client.sh` ad-hoc signs by default (`-s -`), producing a **fresh signature on every build**. So:

> Every client rebuild silently orphans the Accessibility grant. System Settings will still show a "Vant" entry that looks enabled, but the new binary isn't the one that was granted.

Symptom: permission looks granted, dictation records fine, and nothing ever gets pasted.

**Development fix — reset and re-grant after a rebuild:**

```sh
tccutil reset Accessibility com.vant.dictation
tccutil reset Microphone com.vant.dictation
```

**Permanent fix — sign with a stable identity.** A free Apple ID is enough (Xcode → Settings → Accounts → Manage Certificates → **+** → Apple Development); no paid Developer Program required:

```sh
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build-client.sh
```

With a stable signature the grant survives rebuilds — worth setting up before any significant client work.

> **Note:** the bundle ID changed from `com.localflow.dictation` to `com.vant.dictation` during the rename, so grants made before that are orphaned. Reset the old ID once to clear its stale System Settings entry: `tccutil reset Accessibility com.localflow.dictation`.

---

## 8. Timing and timeouts

Several timings are load-bearing rather than arbitrary:

| Value | Where | Why |
|---|---|---|
| 60 s | Whisper budget | Upper bound on transcription. |
| 30 s | Claude budget | Upper bound on cleanup. |
| Whisper + Claude + 30 s | Server `WriteTimeout` (`main.go`) | **Derived, not hardcoded.** Go's `WriteTimeout` covers the entire handler, so it must exceed both upstream calls run back to back — a fixed value silently becomes wrong when a budget changes. |
| 120 s | Client request timeout | Must exceed the server's worst case with margin. |
| 0.25 s | AX messaging timeout | Runs inline on the hotkey path; an unresponsive app must not stall the keypress. |
| 50 ms | Clipboard settle before `⌘V` | Lets the pasteboard server register the write before the paste fires. |
| 200 ms | Clipboard restore delay | Comfortably exceeds the time a frontmost app needs to service the paste. Restoring sooner risks the app reading the *old* clipboard. |
| 1 s | Accessibility poll | Trust state isn't observable. Stops once granted. |

### Clipboard safety

`TextInjector` records `NSPasteboard.changeCount` after writing. If the user copies something during the 200 ms window, the count has moved past Vant's write and **restoration is skipped** rather than clobbering the newer copy.

Known limitation: only `.string` is backed up. A user whose clipboard held an image or rich content gets plain text back. Full `NSPasteboardItem` fidelity is a known follow-up.

---

## 9. Operations

```sh
./scripts/run-backend.sh                       # backend (needs backend/.env)
./scripts/build-client.sh && open client/Vant/Vant.app
```

### Reading the logs

The backend logs the full pipeline for every dictation — the primary debugging tool:

```
[dictate] received upload: filename="vant-….m4a" size=48213 bytes content-type="audio/mp4"
[focus] app="Slack" bundle="com.tinyspeck.slackmacgap" window="#engineering"
[whisper] raw transcript (84 chars):
um so like can you take a look at the deploy when you get a sec
[claude] context=messaging cleaned text (52 chars):
Can you take a look at the deploy when you get a sec?
```

This makes each stage independently diagnosable: whether audio arrived, what app was detected, what Whisper heard, and which prompt was applied.

### Triage

| Symptom | Likely cause |
|---|---|
| Records, nothing pastes | Accessibility grant orphaned by a rebuild — see §7. |
| `[focus]` shows the wrong app | Focus changed before the keypress, or an Electron wrapper reports an unlisted bundle ID. |
| Wrong formatting applied | App classified as `generic`; add its bundle ID to `appcontext.go` (§6). |
| Speech clipped at the start | Recorder not pre-warmed — check `prepareNext()` is called after every stop. |
| `502` on every request | Bad or missing API key; the error text names which upstream failed. |
| Hotkey does nothing | Another app owns `⌃Space` (macOS input-source switching is the usual culprit). |

### Tests

```sh
cd backend && go test ./...     # classification + prompt assembly
cd client/Vant && swift build   # client has no test target yet
```

---

## 10. Known limitations

- **Bundle-ID tables are hand-curated.** Unlisted apps fall back to `generic`. Extending is one line (§6).
- **Browser detection depends on window titles**, which are heuristic and localization-sensitive. A site not in `titleHints` degrades to `generic`.
- **Clipboard backup is text-only** (§8).
- **No client tests.** Backend logic is covered; the Swift side is verified by building and manual use.
- **`Package.swift` instead of `.xcodeproj`.** Xcode 15+ opens it as a full native project; this was chosen because a hand-authored `pbxproj` can't be verified from the command line.
- **Single hardcoded hotkey.** `⌃Space` is not configurable at runtime, and it collides with macOS's default input-source shortcut. Carbon normally wins, but users who rely on that shortcut must disable it.
- **No retry on upstream failure.** A transient 500 from either API loses the dictation; the audio is already deleted by then.

---

## 11. Security and privacy posture

- **Loopback only.** The server binds `127.0.0.1`, never `0.0.0.0` — nothing is reachable from the LAN. Worth preserving deliberately; it's a one-word change to break.
- **No secrets in the client.** Keys live only in the backend environment. `.env` is gitignored.
- **Audio is ephemeral.** Written to a temp `.m4a`, uploaded, and deleted in a `defer` that runs on both success and failure.
- **No persistence.** Vant stores no transcripts, no history, no analytics. Dictation content exists only in logs (stdout) and the two upstream API calls.
- **Sandbox is off, deliberately.** A sandboxed process cannot post `CGEvent`s to other apps or read Accessibility trust. This is the fundamental trade for system-wide paste injection and is documented in `Vant.entitlements`.
