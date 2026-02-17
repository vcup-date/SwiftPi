import Foundation
import PiAI
import PiAgent

// MARK: - Edit Tool

/// Surgical text replacement in files
public struct EditTool {
    public let cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd

        return AgentTool(
            name: "edit",
            label: "Edit",
            description: "Edit a file by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchemaProperty(type: "string", description: "Path to the file to edit (relative or absolute)"),
                    "oldText": JSONSchemaProperty(type: "string", description: "Exact text to find and replace (must match exactly)"),
                    "newText": JSONSchemaProperty(type: "string", description: "New text to replace the old text with")
                ],
                required: ["path", "oldText", "newText"]
            ),
            execute: { _, args, _ in
                let path = args["path"]?.stringValue ?? ""
                let oldString = args["oldText"]?.stringValue ?? ""
                let newString = args["newText"]?.stringValue ?? ""
                let replaceAll = false

                return try editFile(
                    path: path,
                    oldString: oldString,
                    newString: newString,
                    replaceAll: replaceAll,
                    cwd: cwd
                )
            }
        )
    }
}

/// Edit a file by finding and replacing text
public func editFile(
    path: String,
    oldString: String,
    newString: String,
    replaceAll: Bool = false,
    cwd: String
) throws -> AgentToolResult {
    let resolvedPath = resolvePath(path, cwd: cwd)

    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        return AgentToolResult.error("File not found: \(path)")
    }

    guard let data = FileManager.default.contents(atPath: resolvedPath),
          var content = String(data: data, encoding: .utf8) else {
        return AgentToolResult.error("Cannot read file: \(path)")
    }

    // Strip BOM
    if content.hasPrefix("\u{FEFF}") {
        content = String(content.dropFirst())
    }

    // Detect line endings
    let lineEnding: String
    if content.contains("\r\n") {
        lineEnding = "\r\n"
    } else if content.contains("\r") {
        lineEnding = "\r"
    } else {
        lineEnding = "\n"
    }

    // Normalize to \n for matching
    let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let normalizedOld = oldString.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let normalizedNew = newString.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

    if normalizedOld == normalizedNew {
        return AgentToolResult.error("oldText and newText are identical — no changes needed")
    }

    // Count occurrences
    let occurrences = normalizedContent.components(separatedBy: normalizedOld).count - 1

    if occurrences == 0 {
        return AgentToolResult.error("oldText not found in \(path). Make sure the text matches exactly (including whitespace).")
    }

    if occurrences > 1 && !replaceAll {
        return AgentToolResult.error("oldText found \(occurrences) times in \(path). Provide more context to make the match unique.")
    }

    // Perform replacement
    let newContent: String
    if replaceAll {
        newContent = normalizedContent.replacingOccurrences(of: normalizedOld, with: normalizedNew)
    } else {
        if let range = normalizedContent.range(of: normalizedOld) {
            newContent = normalizedContent.replacingCharacters(in: range, with: normalizedNew)
        } else {
            return AgentToolResult.error("oldText not found in \(path)")
        }
    }

    // Restore line endings
    let finalContent: String
    if lineEnding == "\r\n" {
        finalContent = newContent.replacingOccurrences(of: "\n", with: "\r\n")
    } else if lineEnding == "\r" {
        finalContent = newContent.replacingOccurrences(of: "\n", with: "\r")
    } else {
        finalContent = newContent
    }

    // Write back
    try finalContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

    // Generate diff
    let diff = generateUnifiedDiff(
        oldContent: normalizedContent,
        newContent: newContent,
        filePath: path
    )

    // Find first changed line
    let oldLines = normalizedContent.components(separatedBy: "\n")
    let newLines = newContent.components(separatedBy: "\n")
    var firstChangedLine = 1
    for i in 0..<min(oldLines.count, newLines.count) {
        if oldLines[i] != newLines[i] {
            firstChangedLine = i + 1
            break
        }
    }

    let replacements = replaceAll ? occurrences : 1

    return AgentToolResult(
        content: [.text(TextContent(text: "Successfully edited \(path) (\(replacements) replacement\(replacements > 1 ? "s" : ""))\n\n\(diff)"))],
        details: [
            "diff": AnyCodable(diff),
            "firstChangedLine": AnyCodable(firstChangedLine),
            "replacements": AnyCodable(replacements)
        ]
    )
}

/// Generate a unified diff between two strings
public func generateUnifiedDiff(oldContent: String, newContent: String, filePath: String) -> String {
    let oldLines = oldContent.components(separatedBy: "\n")
    let newLines = newContent.components(separatedBy: "\n")

    var diff = "--- a/\(filePath)\n+++ b/\(filePath)\n"

    // Simple diff: find changed region
    var firstDiff = 0
    while firstDiff < oldLines.count && firstDiff < newLines.count && oldLines[firstDiff] == newLines[firstDiff] {
        firstDiff += 1
    }

    var lastDiffOld = oldLines.count - 1
    var lastDiffNew = newLines.count - 1
    while lastDiffOld > firstDiff && lastDiffNew > firstDiff && oldLines[lastDiffOld] == newLines[lastDiffNew] {
        lastDiffOld -= 1
        lastDiffNew -= 1
    }

    // Context
    let contextLines = 3
    let startLine = max(firstDiff - contextLines, 0)
    let endOld = min(lastDiffOld + contextLines + 1, oldLines.count)
    let endNew = min(lastDiffNew + contextLines + 1, newLines.count)

    diff += "@@ -\(startLine + 1),\(endOld - startLine) +\(startLine + 1),\(endNew - startLine) @@\n"

    // Before context
    for i in startLine..<firstDiff {
        diff += " \(oldLines[i])\n"
    }

    // Removed lines
    for i in firstDiff...min(lastDiffOld, oldLines.count - 1) {
        diff += "-\(oldLines[i])\n"
    }

    // Added lines
    for i in firstDiff...min(lastDiffNew, newLines.count - 1) {
        diff += "+\(newLines[i])\n"
    }

    // After context
    let afterStart = max(lastDiffOld, lastDiffNew) + 1
    let afterEnd = max(endOld, endNew)
    for i in afterStart..<min(afterEnd, max(oldLines.count, newLines.count)) {
        let line = i < oldLines.count ? oldLines[i] : (i < newLines.count ? newLines[i] : "")
        diff += " \(line)\n"
    }

    return diff
}
