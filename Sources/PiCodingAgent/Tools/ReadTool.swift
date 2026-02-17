import Foundation
import PiAI
import PiAgent

// MARK: - Read Tool

/// Read file contents with pagination support
public struct ReadTool {
    public let cwd: String
    public let maxLines: Int
    public let maxBytes: Int

    public init(cwd: String, maxLines: Int = 2000, maxBytes: Int = 50 * 1024) {
        self.cwd = cwd
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd
        let maxLines = self.maxLines
        let maxBytes = self.maxBytes

        return AgentTool(
            name: "read",
            label: "Read",
            description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchemaProperty(type: "string", description: "Path to the file to read (relative or absolute)"),
                    "offset": JSONSchemaProperty(type: "number", description: "Line number to start reading from (1-indexed)"),
                    "limit": JSONSchemaProperty(type: "number", description: "Maximum number of lines to read")
                ],
                required: ["path"]
            ),
            execute: { _, args, _ in
                let path = args["path"]?.stringValue ?? ""
                let offset = args["offset"]?.intValue
                let limit = args["limit"]?.intValue

                return try await readFile(
                    path: path,
                    cwd: cwd,
                    offset: offset,
                    limit: limit,
                    maxLines: maxLines,
                    maxBytes: maxBytes
                )
            }
        )
    }
}

/// Read a file and return its contents
public func readFile(
    path: String,
    cwd: String,
    offset: Int? = nil,
    limit: Int? = nil,
    maxLines: Int = 2000,
    maxBytes: Int = 50 * 1024
) async throws -> AgentToolResult {
    let resolvedPath = resolvePath(path, cwd: cwd)

    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        return AgentToolResult.error("File not found: \(path)")
    }

    // Check if image
    let ext = (resolvedPath as NSString).pathExtension.lowercased()
    let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
    if imageExts.contains(ext) {
        return try readImageFile(path: resolvedPath, ext: ext)
    }

    // Read text file
    guard let data = FileManager.default.contents(atPath: resolvedPath),
          let content = String(data: data, encoding: .utf8) else {
        return AgentToolResult.error("Cannot read file (not UTF-8 text): \(path)")
    }

    let allLines = content.components(separatedBy: "\n")
    let totalLines = allLines.count

    // Apply offset and limit
    let startLine = max((offset ?? 1) - 1, 0) // Convert 1-indexed to 0-indexed
    let effectiveLimit = limit ?? maxLines
    let endLine = min(startLine + effectiveLimit, totalLines)

    let selectedLines = Array(allLines[startLine..<endLine])

    // Format with line numbers (cat -n style)
    var outputLines: [String] = []
    var byteCount = 0

    for (idx, line) in selectedLines.enumerated() {
        let lineNum = startLine + idx + 1 // Back to 1-indexed
        var truncatedLine = line
        if truncatedLine.count > 2000 {
            truncatedLine = String(truncatedLine.prefix(2000)) + "... (line truncated)"
        }
        let formatted = "  \(lineNum)\t\(truncatedLine)"
        byteCount += formatted.utf8.count + 1

        if byteCount > maxBytes {
            outputLines.append("... (output truncated at \(maxBytes) bytes)")
            break
        }
        outputLines.append(formatted)
    }

    var result = outputLines.joined(separator: "\n")

    // Add notices
    var notices: [String] = []
    if startLine > 0 || endLine < totalLines {
        notices.append("Showing lines \(startLine + 1)-\(endLine) of \(totalLines)")
    }
    if endLine < totalLines {
        notices.append("Use offset=\(endLine + 1) to continue reading")
    }

    if !notices.isEmpty {
        result = notices.joined(separator: "\n") + "\n\n" + result
    }

    let details: [String: AnyCodable] = [
        "totalLines": AnyCodable(totalLines),
        "startLine": AnyCodable(startLine + 1),
        "endLine": AnyCodable(endLine),
        "truncated": AnyCodable(endLine < totalLines)
    ]

    return AgentToolResult(
        content: [.text(TextContent(text: result))],
        details: details
    )
}

private func readImageFile(path: String, ext: String) throws -> AgentToolResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let base64 = data.base64EncodedString()

    let mimeType: String
    switch ext {
    case "png": mimeType = "image/png"
    case "jpg", "jpeg": mimeType = "image/jpeg"
    case "gif": mimeType = "image/gif"
    case "webp": mimeType = "image/webp"
    case "svg": mimeType = "image/svg+xml"
    case "bmp": mimeType = "image/bmp"
    default: mimeType = "application/octet-stream"
    }

    return AgentToolResult(
        content: [
            .text(TextContent(text: "Image file: \(path) (\(data.count) bytes)")),
            .image(ImageContent(data: base64, mimeType: mimeType))
        ],
        details: ["size": AnyCodable(data.count), "mimeType": AnyCodable(mimeType)]
    )
}
