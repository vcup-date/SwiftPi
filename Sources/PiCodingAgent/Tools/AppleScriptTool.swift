import Foundation
import PiAI
import PiAgent

// MARK: - AppleScript Tool

/// Execute AppleScript for macOS automation — control apps, show dialogs, manage windows, etc.
public struct AppleScriptTool {
    public let defaultTimeout: TimeInterval

    public init(defaultTimeout: TimeInterval = 30) {
        self.defaultTimeout = defaultTimeout
    }

    public var agentTool: AgentTool {
        let defaultTimeout = self.defaultTimeout

        return AgentTool(
            name: "applescript",
            label: "AppleScript",
            description: """
                Execute AppleScript for macOS automation. Use this to control apps (Finder, Safari, \
                Mail, Music, Terminal, etc.), show dialogs, manage windows, read/write files via \
                Finder, send notifications, and automate workflows. The script runs via osascript. \
                For JavaScript for Automation (JXA), set language to "javascript".
                """,
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "script": JSONSchemaProperty(type: "string", description: "AppleScript or JXA code to execute"),
                    "language": JSONSchemaProperty(type: "string", description: "Script language: \"applescript\" (default) or \"javascript\" (JXA)"),
                    "timeout": JSONSchemaProperty(type: "number", description: "Timeout in seconds (default: 30)")
                ],
                required: ["script"]
            ),
            execute: { toolCallId, args, onUpdate in
                let script = args["script"]?.stringValue ?? ""
                let language = args["language"]?.stringValue ?? "applescript"
                let timeout = args["timeout"]?.doubleValue ?? defaultTimeout

                return try await executeAppleScript(
                    script: script,
                    language: language,
                    timeout: timeout,
                    onUpdate: onUpdate
                )
            }
        )
    }
}

/// Execute an AppleScript or JXA script via osascript
public func executeAppleScript(
    script: String,
    language: String = "applescript",
    timeout: TimeInterval = 30,
    onUpdate: AgentToolUpdateCallback? = nil
) async throws -> AgentToolResult {
    let langFlag = language == "javascript" ? "JavaScript" : "AppleScript"

    // Write script to temp file to avoid shell escaping issues
    let tempDir = FileManager.default.temporaryDirectory
    let ext = language == "javascript" ? "js" : "scpt"
    let fileName = "swiftpi_script_\(UUID().uuidString).\(ext)"
    let tempFile = tempDir.appendingPathComponent(fileName)

    try script.write(to: tempFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let command = "osascript -l \(langFlag) \(tempFile.path)"

    return try await executeBash(
        command: command,
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        timeout: timeout,
        onUpdate: onUpdate
    )
}
