import AppKit
import ApplicationServices

/// Identifies the application that had keyboard focus when a dictation
/// started — the app the cleaned text will ultimately be pasted into.
///
/// The backend uses this to pick a cleanup prompt: an email client gets an
/// email, a terminal gets a command, an AI assistant gets a well-formed
/// prompt. Classification deliberately lives on the backend, so prompt
/// tuning doesn't require rebuilding (and re-signing) this app.
struct FocusContext {
    let bundleIdentifier: String
    let applicationName: String
    let windowTitle: String

    /// Snapshots the frontmost application. Call this when recording
    /// *starts*: the user is focused on their target app at that moment,
    /// and Vant itself never becomes frontmost (it runs as an
    /// `.accessory` app and its indicator is a non-activating panel).
    static func current() -> FocusContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        return FocusContext(
            bundleIdentifier: app.bundleIdentifier ?? "",
            applicationName: app.localizedName ?? "",
            windowTitle: focusedWindowTitle(pid: app.processIdentifier) ?? ""
        )
    }

    /// Reads the focused window's title via the Accessibility API.
    ///
    /// This is what disambiguates browsers, where the bundle ID says
    /// nothing useful — "Inbox (12) - you@gmail.com - Gmail" tells the
    /// backend far more than `com.google.Chrome` does. Returns nil when
    /// Accessibility isn't trusted yet or the app exposes no title, which
    /// the backend handles as "unknown".
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)

        // Never let an unresponsive app stall the hotkey path — this runs
        // inline with the user pressing ⌃Space.
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }

        // swiftlint:disable:next force_cast
        let window = windowValue as! AXUIElement

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String,
              !title.isEmpty
        else { return nil }

        return title
    }
}
