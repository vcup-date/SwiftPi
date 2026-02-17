import Foundation
import PiAI
import PiAgent

// MARK: - Find Tool

/// Find files by glob pattern
public struct FindTool {
    public let cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd

        return AgentTool(
            name: "find",
            label: "Find",
            description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first).",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "pattern": JSONSchemaProperty(type: "string", description: "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'"),
                    "path": JSONSchemaProperty(type: "string", description: "Directory to search in (default: current directory)"),
                    "limit": JSONSchemaProperty(type: "number", description: "Maximum number of results (default: 1000)")
                ],
                required: ["pattern"]
            ),
            execute: { _, args, _ in
                let pattern = args["pattern"]?.stringValue ?? ""
                let path = args["path"]?.stringValue
                let limit = args["limit"]?.intValue ?? 1000

                return try await findFiles(
                    pattern: pattern,
                    path: path,
                    limit: limit,
                    cwd: cwd
                )
            }
        )
    }
}

/// Find files matching a glob pattern using find or fd
public func findFiles(
    pattern: String,
    path: String? = nil,
    limit: Int = 1000,
    cwd: String
) async throws -> AgentToolResult {
    let searchPath = path.map { resolvePath($0, cwd: cwd) } ?? cwd

    // Try fd first, fall back to find
    var executable: String
    var args: [String]

    if FileManager.default.fileExists(atPath: "/usr/local/bin/fd") {
        executable = "/usr/local/bin/fd"
        args = ["--glob", "--hidden", "--color=never", "--max-results", "\(limit)", pattern, searchPath]
    } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/fd") {
        executable = "/opt/homebrew/bin/fd"
        args = ["--glob", "--hidden", "--color=never", "--max-results", "\(limit)", pattern, searchPath]
    } else {
        // Use find
        executable = "/usr/bin/find"
        args = [searchPath, "-name", pattern, "-maxdepth", "10"]
        if !pattern.contains("*") {
            args = [searchPath, "-name", "*\(pattern)*", "-maxdepth", "10"]
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    var output = String(data: outputData, encoding: .utf8) ?? ""

    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return AgentToolResult.text("No files found matching pattern: \(pattern)")
    }

    // Make paths relative
    output = output.replacingOccurrences(of: cwd + "/", with: "")

    // Apply limit
    var lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    var limitReached = false
    if lines.count > limit {
        lines = Array(lines.prefix(limit))
        limitReached = true
    }

    var result = lines.joined(separator: "\n")
    var notices: [String] = []

    if limitReached {
        notices.append("Result limit (\(limit)) reached. Use limit parameter for more.")
    }

    if !notices.isEmpty {
        result = notices.joined(separator: "\n") + "\n\n" + result
    }

    return AgentToolResult(
        content: [.text(TextContent(text: result))],
        details: ["count": AnyCodable(lines.count), "limitReached": AnyCodable(limitReached)]
    )
}
