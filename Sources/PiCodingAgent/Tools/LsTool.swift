import Foundation
import PiAI
import PiAgent

// MARK: - Ls Tool

/// List directory contents
public struct LsTool {
    public let cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd

        return AgentTool(
            name: "ls",
            label: "List",
            description: "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchemaProperty(type: "string", description: "Directory to list (default: current directory)"),
                    "limit": JSONSchemaProperty(type: "number", description: "Maximum number of entries to return (default: 500)")
                ]
            ),
            execute: { _, args, _ in
                let path = args["path"]?.stringValue
                let limit = args["limit"]?.intValue ?? 500

                return try listDirectory(path: path, limit: limit, cwd: cwd)
            }
        )
    }
}

/// List directory contents
public func listDirectory(path: String? = nil, limit: Int = 500, cwd: String) throws -> AgentToolResult {
    let resolvedPath = path.map { resolvePath($0, cwd: cwd) } ?? cwd

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
        return AgentToolResult.error("Not a directory: \(path ?? ".")")
    }

    let contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)

    // Sort alphabetically (case-insensitive)
    let sorted = contents.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    var entries: [String] = []
    var limitReached = false

    for (idx, name) in sorted.enumerated() {
        if idx >= limit {
            limitReached = true
            break
        }

        let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
        var isDirEntry: ObjCBool = false
        FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirEntry)

        if isDirEntry.boolValue {
            entries.append(name + "/")
        } else {
            entries.append(name)
        }
    }

    if entries.isEmpty {
        return AgentToolResult.text("(empty directory)")
    }

    var result = entries.joined(separator: "\n")

    if limitReached {
        result = "Entry limit (\(limit)) reached. \(sorted.count) total entries.\n\n" + result
    }

    return AgentToolResult(
        content: [.text(TextContent(text: result))],
        details: ["count": AnyCodable(entries.count), "total": AnyCodable(sorted.count)]
    )
}
