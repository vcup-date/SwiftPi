import Foundation
import PiAI
import PiAgent

// MARK: - Swift Tool

/// Execute Swift code like an Xcode Playground — write a snippet, see the output.
/// Supports UI mode: opens an AppKit window for visual output (AppKit preferred, SwiftUI also supported).
public struct SwiftTool {
    public let cwd: String
    public let defaultTimeout: TimeInterval

    public init(cwd: String, defaultTimeout: TimeInterval = 60) {
        self.cwd = cwd
        self.defaultTimeout = defaultTimeout
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd
        let defaultTimeout = self.defaultTimeout

        return AgentTool(
            name: "swift",
            label: "Swift Playground",
            description: "Execute a Swift code snippet like an Xcode Playground. Use print() for output. Set ui: true to open an AppKit/SwiftUI preview window. Read ~/.swiftpi/skills/swift-playground.md for UI mode details.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "code": JSONSchemaProperty(type: "string", description: "Swift code to execute"),
                    "ui": JSONSchemaProperty(type: "boolean", description: "Set to true to open a preview window (AppKit or SwiftUI)"),
                    "timeout": JSONSchemaProperty(type: "number", description: "Timeout in seconds (default: 60)")
                ],
                required: ["code"]
            ),
            execute: { toolCallId, args, onUpdate in
                let code = args["code"]?.stringValue ?? ""
                let ui = args["ui"]?.boolValue ?? false
                let timeout = args["timeout"]?.doubleValue ?? defaultTimeout

                return try await executeSwift(
                    code: code,
                    cwd: cwd,
                    timeout: timeout,
                    ui: ui,
                    onUpdate: onUpdate
                )
            }
        )
    }
}

/// Execute a Swift snippet and return results
public func executeSwift(
    code: String,
    cwd: String,
    timeout: TimeInterval = 60,
    ui: Bool = false,
    onUpdate: AgentToolUpdateCallback? = nil
) async throws -> AgentToolResult {
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = "swiftpi_playground_\(UUID().uuidString).swift"
    let tempFile = tempDir.appendingPathComponent(fileName)

    let finalCode: String
    if ui {
        finalCode = wrapUICode(code)
    } else {
        finalCode = code
    }

    try finalCode.write(to: tempFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let result = try await executeBash(
        command: "swift \(tempFile.path)",
        cwd: cwd,
        timeout: timeout,
        onUpdate: onUpdate
    )

    return result
}

/// Wrap user code in an AppKit window host. Supports both NSView (previewContent) and SwiftUI (previewView).
private func wrapUICode(_ userCode: String) -> String {
    return """
    import AppKit
    import SwiftUI

    // --- User Code ---
    \(userCode)
    // --- End User Code ---

    // Preview Host
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "SwiftPi Preview"
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .windowBackgroundColor
    window.center()

    // Detect what the user defined and display it
    func setupPreviewContent() {
        // Check for AppKit NSView via previewContent
        if let nsView = (previewContent as Any) as? NSView {
            window.contentView = nsView
            print("Displaying AppKit NSView preview")
            return
        }

        // Check for SwiftUI View via previewView
        let candidate = (previewView as Any)
        if let wrapped = AnyView(_fromValue: candidate) {
            let hosting = NSHostingView(rootView: wrapped)
            window.contentView = hosting
            print("Displaying SwiftUI preview")
            return
        }

        // Fallback
        let label = NSTextField(labelWithString: "No preview content found.\\nDefine `let previewContent: NSView` or `let previewView`.")
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        window.contentView = label
        print("No previewContent or previewView found")
    }

    setupPreviewContent()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // Auto-close after timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("Preview auto-closed after 30s")
        app.terminate(nil)
    }
    app.run()
    """
}

private extension AnyCodable {
    var boolValue: Bool? {
        value as? Bool
    }
}
