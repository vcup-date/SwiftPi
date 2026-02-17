import Foundation
import PiAI
import PiAgent

// MARK: - Write Tool

/// Write/create files
public struct WriteTool {
    public let cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd

        return AgentTool(
            name: "write",
            label: "Write",
            description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchemaProperty(type: "string", description: "Path to the file to write (relative or absolute)"),
                    "content": JSONSchemaProperty(type: "string", description: "Content to write to the file")
                ],
                required: ["path", "content"]
            ),
            execute: { _, args, _ in
                let path = args["path"]?.stringValue ?? ""
                let content = args["content"]?.stringValue ?? ""

                return try writeFile(path: path, content: content, cwd: cwd)
            }
        )
    }
}

/// Write content to a file
public func writeFile(path: String, content: String, cwd: String) throws -> AgentToolResult {
    let resolvedPath = resolvePath(path, cwd: cwd)

    // Create parent directories
    let parentDir = (resolvedPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

    // Write file
    try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

    let bytes = content.utf8.count
    return AgentToolResult.text("Successfully wrote \(bytes) bytes to \(path)")
}
