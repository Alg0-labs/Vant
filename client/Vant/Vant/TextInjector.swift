import AppKit
import CoreGraphics
import Foundation

/// Types cleaned dictation text into whatever app currently has keyboard
/// focus, by round-tripping through the system clipboard: back up → write →
/// synthesize ⌘V → restore.
enum TextInjector {
    private static let pasteSettleDelay: TimeInterval = 0.05
    private static let clipboardRestoreDelay: TimeInterval = 0.2

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        // Give the pasteboard server a moment to register the new contents
        // before the synthetic paste event fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteSettleDelay) {
            sendCommandV()

            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                // If the user copied something themselves during the
                // window, changeCount has moved past our write — skip the
                // restore rather than clobber their newer clipboard entry.
                guard pasteboard.changeCount == changeCountAfterWrite else { return }
                pasteboard.clearContents()
                if let previousContents {
                    pasteboard.setString(previousContents, forType: .string)
                }
            }
        }
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let vKeyCode: CGKeyCode = 0x09 // 'V'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
