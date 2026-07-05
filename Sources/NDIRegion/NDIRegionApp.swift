import AppKit
import SwiftUI

@main
struct NDIRegionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = FeedStore()

    var body: some Scene {
        Window("Capture NDI Region", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 900, height: 380)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running as a bare SPM binary (no bundle): show in Dock,
        // allow the window to come to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
