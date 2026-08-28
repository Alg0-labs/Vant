import AppKit
import SwiftUI

@main
struct VantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra("Vant", systemImage: appState.phase.menuBarSymbol) {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Handles process-launch setup that `MenuBarExtra` has no lifecycle hook
/// for: hiding the Dock icon and registering the global hotkey before any
/// menu bar interaction occurs.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
        RecordingIndicatorController.shared.start()
    }
}
