import Foundation

// MARK: - Prompt Templates

/// A reusable prompt template with argument substitution
public struct PromptTemplate: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var content: String
    public var source: String // "user", "project", "path"
    public var filePath: String

    public init(name: String, description: String, content: String, source: String, filePath: String) {
        self.name = name
        self.description = description
        self.content = content
        self.source = source
        self.filePath = filePath
    }
}

/// Load prompt templates from directories
public func loadPromptTemplates(
    cwd: String? = nil,
    agentDir: String? = nil,
    promptPaths: [String] = [],
    includeDefaults: Bool = true
) -> [PromptTemplate] {
    var templates: [PromptTemplate] = []
    let defaultAgentDir = agentDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".swiftpi")

    if includeDefaults {
        // Global prompts
        let globalDir = (defaultAgentDir as NSString).appendingPathComponent("prompts")
        templates.append(contentsOf: loadTemplatesFromDir(globalDir, source: "user"))

        // Project prompts
        if let cwd {
            let projectDir = (cwd as NSString).appendingPathComponent(".swiftpi/prompts")
            templates.append(contentsOf: loadTemplatesFromDir(projectDir, source: "project"))
        }
    }

    // Explicit paths
    for path in promptPaths {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
            if isDir.boolValue {
                templates.append(contentsOf: loadTemplatesFromDir(expanded, source: "path"))
            } else if expanded.hasSuffix(".md") {
                if let t = loadTemplateFile(expanded, source: "path") {
                    templates.append(t)
                }
            }
        }
    }

    return templates
}

/// Load templates from a directory
private func loadTemplatesFromDir(_ dir: String, source: String) -> [PromptTemplate] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }

    return files.compactMap { file -> PromptTemplate? in
        guard file.hasSuffix(".md"), !file.hasPrefix(".") else { return nil }
        let path = (dir as NSString).appendingPathComponent(file)
        return loadTemplateFile(path, source: source)
    }
}

/// Build source label for a prompt template
private func buildSourceLabel(_ source: String, path: String) -> String {
    switch source {
    case "user": return "(user)"
    case "project": return "(project)"
    default:
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = base.isEmpty ? "path" : base
        return "(path:\(label))"
    }
}

/// Load a single template file
private func loadTemplateFile(_ path: String, source: String) -> PromptTemplate? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

    let (frontmatter, body) = parseTemplateFrontmatter(content)

    let name: String
    if let fmName = frontmatter["name"] {
        name = fmName
    } else {
        name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // Get description from frontmatter or first non-empty line
    var description = frontmatter["description"] ?? ""
    if description.isEmpty {
        let firstLine = body.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        if let firstLine {
            description = String(firstLine.prefix(60))
            if firstLine.count > 60 { description += "..." }
        }
    }

    // Append source to description
    let sourceLabel = buildSourceLabel(source, path: path)
    description = description.isEmpty ? sourceLabel : "\(description) \(sourceLabel)"

    return PromptTemplate(
        name: name,
        description: description,
        content: body,
        source: source,
        filePath: path
    )
}

/// Expand a prompt template with arguments
public func expandPromptTemplate(_ text: String, templates: [PromptTemplate]) -> String {
    guard text.hasPrefix("/") else { return text }

    // Parse command and arguments
    let parts = text.dropFirst() // Remove "/"
    let components = parseCommandArgs(String(parts))
    guard let templateName = components.first else { return text }
    let args = Array(components.dropFirst())

    // Find template
    guard let template = templates.first(where: { $0.name == templateName }) else {
        return text // No matching template
    }

    // Substitute arguments
    return substituteArgs(template.content, args: args)
}

/// Parse command arguments (respects quotes)
public func parseCommandArgs(_ input: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inQuote: Character?

    for char in input {
        if let q = inQuote {
            if char == q {
                inQuote = nil
            } else {
                current.append(char)
            }
        } else if char == "\"" || char == "'" {
            inQuote = char
        } else if char == " " {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }

    if !current.isEmpty {
        args.append(current)
    }

    return args
}

/// Substitute arguments in a template
public func substituteArgs(_ content: String, args: [String]) -> String {
    var result = content

    // $1, $2, etc.
    for (idx, arg) in args.enumerated() {
        result = result.replacingOccurrences(of: "$\(idx + 1)", with: arg)
    }

    // $@ or $ARGUMENTS — all args joined
    result = result.replacingOccurrences(of: "$@", with: args.joined(separator: " "))
    result = result.replacingOccurrences(of: "$ARGUMENTS", with: args.joined(separator: " "))

    // ${@:N} — args from Nth onwards (1-indexed)
    let slicePattern = try? NSRegularExpression(pattern: "\\$\\{@:(\\d+)\\}")
    if let matches = slicePattern?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
        for match in matches.reversed() {
            if let range = Range(match.range, in: result),
               let nRange = Range(match.range(at: 1), in: result),
               let n = Int(result[nRange]) {
                let startIdx = n - 1 // Convert to 0-indexed
                let sliced = args.dropFirst(startIdx).joined(separator: " ")
                result.replaceSubrange(range, with: sliced)
            }
        }
    }

    // ${@:N:M} — M args starting from Nth (1-indexed)
    let slicePattern2 = try? NSRegularExpression(pattern: "\\$\\{@:(\\d+):(\\d+)\\}")
    if let matches = slicePattern2?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
        for match in matches.reversed() {
            if let range = Range(match.range, in: result),
               let nRange = Range(match.range(at: 1), in: result),
               let mRange = Range(match.range(at: 2), in: result),
               let n = Int(result[nRange]),
               let m = Int(result[mRange]) {
                let startIdx = n - 1
                let endIdx = min(startIdx + m, args.count)
                let sliced = args[startIdx..<endIdx].joined(separator: " ")
                result.replaceSubrange(range, with: sliced)
            }
        }
    }

    return result
}

// MARK: - Helpers

private func parseTemplateFrontmatter(_ content: String) -> (frontmatter: [String: String], body: String) {
    let lines = content.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
        return ([:], content)
    }

    var frontmatter: [String: String] = [:]
    var endIndex = 1

    for i in 1..<lines.count {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        if line == "---" {
            endIndex = i + 1
            break
        }
        if let colonIndex = line.firstIndex(of: ":") {
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            frontmatter[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    let body = lines[endIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (frontmatter, body)
}
