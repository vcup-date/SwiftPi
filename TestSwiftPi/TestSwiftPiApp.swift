import SwiftUI
import AppKit
import PiAI
import PiAgent
import PiCodingAgent
import TestSwiftPiLib

@main
struct TestSwiftPiApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Set app icon from bundled resource (for SPM-built executables)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
    }
}
