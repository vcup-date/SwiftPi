import Foundation
import PiAI
import PiAgent

// MARK: - Grep Tool

/// Search file contents with regex patterns
public struct GrepTool {
    public let cwd: String
    public let maxLineLength: Int
    public let maxBytes: Int

    public init(cwd: String, maxLineLength: Int = 500, maxBytes: Int = 50 * 1024) {
        self.cwd = cwd
        self.maxLineLength = maxLineLength
        self.maxBytes = maxBytes
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd
        let maxLineLen = self.maxLineLength
        let maxBytes = self.maxBytes

        return AgentTool(
            name: "grep",
            label: "Grep",
            description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "pattern": JSONSchemaProperty(type: "string", description: "Search pattern (regex or literal string)"),
                    "path": JSONSchemaProperty(type: "string", description: "Directory or file to search (default: current directory)"),
                    "glob": JSONSchemaProperty(type: "string", description: "Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'"),
                    "ignoreCase": JSONSchemaProperty(type: "boolean", description: "Case-insensitive search (default: false)"),
                    "literal": JSONSchemaProperty(type: "boolean", description: "Treat pattern as literal string instead of regex (default: false)"),
                    "context": JSONSchemaProperty(type: "number", description: "Number of lines to show before and after each match (default: 0)"),
                    "limit": JSONSchemaProperty(type: "number", description: "Maximum number of matches to return (default: 100)")
                ],
                required: ["pattern"]
            ),
            execute: { _, args, _ in
                let pattern = args["pattern"]?.stringValue ?? ""
                let path = args["path"]?.stringValue
                let glob = args["glob"]?.stringValue
                let ignoreCase = args["ignoreCase"]?.boolValue ?? false
                let literal = args["literal"]?.boolValue ?? false
                let context = args["context"]?.intValue ?? 0
                let limit = args["limit"]?.intValue ?? 100

                return try await grepFiles(
                    pattern: pattern,
                    path: path,
                    glob: glob,
                    ignoreCase: ignoreCase,
                    literal: literal,
                    context: context,
                    limit: limit,
                    cwd: cwd,
                    maxLineLength: maxLineLen,
                    maxBytes: maxBytes
                )
            }
        )
    }
}

/// Search files using grep (or ripgrep if available)
public func grepFiles(
    pattern: String,
    path: String? = nil,
    glob: String? = nil,
    ignoreCase: Bool = false,
    literal: Bool = false,
    context: Int = 0,
    limit: Int = 100,
    cwd: String,
    maxLineLength: Int = 500,
    maxBytes: Int = 50 * 1024
) async throws -> AgentToolResult {
    let searchPath = path.map { resolvePath($0, cwd: cwd) } ?? cwd

    // Try using ripgrep first, fall back to grep
    var args: [String] = []
    var executable = "/usr/bin/grep"

    // Check for ripgrep
    if FileManager.default.fileExists(atPath: "/usr/local/bin/rg") {
        executable = "/usr/local/bin/rg"
    } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/rg") {
        executable = "/opt/homebrew/bin/rg"
    }

    let isRipgrep = executable.hasSuffix("rg")

    if isRipgrep {
        args = ["--no-heading", "--line-number", "--color=never", "-m", "\(limit)"]
        if ignoreCase { args.append("-i") }
        if literal { args.append("-F") }
        if context > 0 { args.append(contentsOf: ["-C", "\(context)"]) }
        if let glob { args.append(contentsOf: ["-g", glob]) }
        args.append(pattern)
        args.append(searchPath)
    } else {
        args = ["-r", "-n", "--color=never"]
        if ignoreCase { args.append("-i") }
        if literal { args.append("-F") }
        if context > 0 { args.append(contentsOf: ["-C", "\(context)"]) }
        if let glob {
            args.append(contentsOf: ["--include", glob])
        }
        args.append(pattern)
        args.append(searchPath)
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

    if output.isEmpty {
        return AgentToolResult.text("No matches found for pattern: \(pattern)")
    }

    // Make paths relative
    if searchPath != cwd {
        // Keep as-is
    } else {
        output = output.replacingOccurrences(of: cwd + "/", with: "")
    }

    // Truncate long lines
    var lines = output.components(separatedBy: "\n")
    var matchCount = 0
    var truncatedLines: [String] = []
    var byteCount = 0

    for line in lines {
        if byteCount > maxBytes {
            truncatedLines.append("... (output truncated)")
            break
        }

        var truncatedLine = line
        if truncatedLine.count > maxLineLength {
            truncatedLine = String(truncatedLine.prefix(maxLineLength)) + "..."
        }

        truncatedLines.append(truncatedLine)
        byteCount += truncatedLine.utf8.count + 1

        if !line.contains("--") && !line.isEmpty { // Not a context separator
            matchCount += 1
        }
    }

    let result = truncatedLines.joined(separator: "\n")

    var notices: [String] = []
    if matchCount >= limit {
        notices.append("Match limit (\(limit)) reached. Use limit parameter for more.")
    }
    if byteCount > maxBytes {
        notices.append("Output truncated at \(maxBytes) bytes.")
    }

    var finalResult = result
    if !notices.isEmpty {
        finalResult = notices.joined(separator: "\n") + "\n\n" + result
    }

    return AgentToolResult(
        content: [.text(TextContent(text: finalResult))],
        details: ["matchCount": AnyCodable(matchCount)]
    )
}
