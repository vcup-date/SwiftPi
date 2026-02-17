import Foundation

// MARK: - Skill Types

/// A loaded skill
public struct Skill: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var content: String
    public var filePath: String
    public var baseDir: String
    public var source: SkillSource
    public var disableModelInvocation: Bool
    public var isSwiftScript: Bool
    /// True when loaded from a directory (skill-name/SKILL.md)
    public var isDirectorySkill: Bool
    /// Additional resource files in the skill directory (relative paths)
    public var resourceFiles: [String]

    public init(name: String, description: String, content: String, filePath: String, baseDir: String, source: SkillSource, disableModelInvocation: Bool = false, isSwiftScript: Bool = false, isDirectorySkill: Bool = false, resourceFiles: [String] = []) {
        self.name = name
        self.description = description
        self.content = content
        self.filePath = filePath
        self.baseDir = baseDir
        self.source = source
        self.disableModelInvocation = disableModelInvocation
        self.isSwiftScript = isSwiftScript
        self.isDirectorySkill = isDirectorySkill
        self.resourceFiles = resourceFiles
    }
}

/// Where a skill was loaded from
public enum SkillSource: String, Sendable {
    case builtin
    case user
    case project
    case path
}

/// Diagnostic from skill loading
public struct SkillDiagnostic: Sendable {
    public var message: String
    public var severity: Severity
    public var skillName: String?
    public var filePath: String?

    public enum Severity: String, Sendable {
        case warning, error
    }
}

/// Result of loading skills
public struct LoadSkillsResult: Sendable {
    public var skills: [Skill]
    public var diagnostics: [SkillDiagnostic]
}

// MARK: - Skill Loader

/// Load skills from directories
public func loadSkills(
    cwd: String? = nil,
    agentDir: String? = nil,
    skillPaths: [String] = [],
    includeDefaults: Bool = true
) -> LoadSkillsResult {
    var skills: [Skill] = []
    var diagnostics: [SkillDiagnostic] = []

    let defaultAgentDir = agentDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".swiftpi")

    // Load from default locations
    if includeDefaults {
        // Deploy builtin skills if they don't exist yet
        let globalSkillsDir = (defaultAgentDir as NSString).appendingPathComponent("skills")
        BuiltinSkills.deployIfNeeded(to: globalSkillsDir)

        // Global skills
        let globalResult = loadSkillsFromDir(globalSkillsDir, source: .user)
        skills.append(contentsOf: globalResult.skills)
        diagnostics.append(contentsOf: globalResult.diagnostics)

        // Project skills
        if let cwd {
            let projectSkillsDir = (cwd as NSString).appendingPathComponent(".swiftpi/skills")
            let projectResult = loadSkillsFromDir(projectSkillsDir, source: .project)
            skills.append(contentsOf: projectResult.skills)
            diagnostics.append(contentsOf: projectResult.diagnostics)
        }
    }

    // Load from explicit paths
    for path in skillPaths {
        let expanded = (path as NSString).expandingTildeInPath
        if isDirectory(expanded) {
            let result = loadSkillsFromDir(expanded, source: .path)
            skills.append(contentsOf: result.skills)
            diagnostics.append(contentsOf: result.diagnostics)
        } else if expanded.hasSuffix(".md") {
            if let skill = loadSkillFile(expanded, source: .path) {
                skills.append(skill.skill)
                diagnostics.append(contentsOf: skill.diagnostics)
            }
        }
    }

    // Tag builtin skills
    let builtinNames = BuiltinSkills.builtinNames
    for i in skills.indices {
        if builtinNames.contains(skills[i].name) && skills[i].source == .user {
            skills[i].source = .builtin
        }
    }

    // Check for collisions
    var seen: [String: Skill] = [:]
    for skill in skills {
        if let existing = seen[skill.name] {
            diagnostics.append(SkillDiagnostic(
                message: "Skill '\(skill.name)' from \(skill.source.rawValue) conflicts with existing from \(existing.source.rawValue)",
                severity: .warning,
                skillName: skill.name,
                filePath: skill.filePath
            ))
        }
        seen[skill.name] = skill
    }

    return LoadSkillsResult(skills: skills, diagnostics: diagnostics)
}

/// Load skills from a single directory
public func loadSkillsFromDir(_ dir: String, source: SkillSource) -> LoadSkillsResult {
    var skills: [Skill] = []
    var diagnostics: [SkillDiagnostic] = []

    guard isDirectory(dir) else { return LoadSkillsResult(skills: [], diagnostics: []) }

    // Direct .md and .swift files
    if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
        for file in files {
            let fullPath = (dir as NSString).appendingPathComponent(file)

            if file.hasSuffix(".md") && !file.hasPrefix(".") {
                if let result = loadSkillFile(fullPath, source: source) {
                    skills.append(result.skill)
                    diagnostics.append(contentsOf: result.diagnostics)
                }
            }

            // Swift script skills
            if file.hasSuffix(".swift") && !file.hasPrefix(".") {
                if let result = loadSwiftSkillFile(fullPath, source: source) {
                    skills.append(result.skill)
                    diagnostics.append(contentsOf: result.diagnostics)
                }
            }

            // Check subdirectories for SKILL.md (Claude Agent Skills directory format)
            if isDirectory(fullPath) && !file.hasPrefix(".") && file != "node_modules" {
                let skillMd = (fullPath as NSString).appendingPathComponent("SKILL.md")
                if FileManager.default.fileExists(atPath: skillMd) {
                    if var result = loadSkillFile(skillMd, source: source, expectedName: file) {
                        result.skill.isDirectorySkill = true
                        // Enumerate resource files in the skill directory
                        result.skill.resourceFiles = enumerateResourceFiles(in: fullPath)
                        skills.append(result.skill)
                        diagnostics.append(contentsOf: result.diagnostics)
                    }
                }
            }
        }
    }

    return LoadSkillsResult(skills: skills, diagnostics: diagnostics)
}

/// Load a single skill from a .md file
private func loadSkillFile(_ path: String, source: SkillSource, expectedName: String? = nil) -> (skill: Skill, diagnostics: [SkillDiagnostic])? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

    var diagnostics: [SkillDiagnostic] = []

    // Parse YAML frontmatter
    let (frontmatter, body) = parseFrontmatter(content)

    let name: String
    if let fmName = frontmatter["name"] {
        name = fmName
    } else if let expectedName {
        name = expectedName
    } else {
        name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // Validate name
    let nameRegex = try? NSRegularExpression(pattern: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    if nameRegex?.firstMatch(in: name, range: range) == nil {
        diagnostics.append(SkillDiagnostic(
            message: "Skill name '\(name)' must be lowercase, alphanumeric with hyphens only",
            severity: .warning,
            skillName: name,
            filePath: path
        ))
    }

    if name.count > 64 {
        diagnostics.append(SkillDiagnostic(
            message: "Skill name '\(name)' exceeds 64 characters",
            severity: .warning,
            skillName: name,
            filePath: path
        ))
    }

    let description = frontmatter["description"] ?? extractFirstLine(body)

    if description.isEmpty {
        diagnostics.append(SkillDiagnostic(
            message: "Skill '\(name)' has no description",
            severity: .warning,
            skillName: name,
            filePath: path
        ))
    }

    if description.count > 1024 {
        diagnostics.append(SkillDiagnostic(
            message: "Skill '\(name)' description exceeds 1024 characters",
            severity: .warning,
            skillName: name,
            filePath: path
        ))
    }

    let disableModelInvocation = frontmatter["disableModelInvocation"]?.lowercased() == "true"
    let baseDir = (path as NSString).deletingLastPathComponent

    let skill = Skill(
        name: name,
        description: description,
        content: body,
        filePath: path,
        baseDir: baseDir,
        source: source,
        disableModelInvocation: disableModelInvocation
    )

    return (skill, diagnostics)
}

/// Format skills for inclusion in the system prompt
public func formatSkillsForPrompt(_ skills: [Skill]) -> String {
    let visibleSkills = skills.filter { !$0.disableModelInvocation }
    guard !visibleSkills.isEmpty else { return "" }

    var lines: [String] = [
        "",
        "",
        "The following skills provide specialized instructions for specific tasks.",
        "Use the read tool to load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
        "",
        "<available_skills>",
    ]

    for skill in visibleSkills {
        lines.append("  <skill>")
        lines.append("    <name>\(escapeXml(skill.name))</name>")
        lines.append("    <description>\(escapeXml(skill.description))</description>")
        lines.append("    <location>\(escapeXml(skill.filePath))</location>")
        if skill.isDirectorySkill {
            lines.append("    <type>directory</type>")
            lines.append("    <base_dir>\(escapeXml(skill.baseDir))</base_dir>")
            if !skill.resourceFiles.isEmpty {
                lines.append("    <resources>\(escapeXml(skill.resourceFiles.joined(separator: ", ")))</resources>")
            }
        }
        lines.append("  </skill>")
    }

    lines.append("</available_skills>")

    return lines.joined(separator: "\n")
}

private func escapeXml(_ str: String) -> String {
    return str
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

/// Load a Swift script as a skill — uses comment-based frontmatter: // name: ..., // description: ...
private func loadSwiftSkillFile(_ path: String, source: SkillSource) -> (skill: Skill, diagnostics: [SkillDiagnostic])? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

    var diagnostics: [SkillDiagnostic] = []

    // Parse comment-based frontmatter from leading // comments
    var meta: [String: String] = [:]
    var bodyLines: [String] = []
    var inHeader = true
    for line in content.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if inHeader && trimmed.hasPrefix("//") {
            let commentBody = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let colonIdx = commentBody.firstIndex(of: ":") {
                let key = String(commentBody[commentBody.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let val = String(commentBody[commentBody.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                meta[key] = val
            }
        } else {
            if inHeader && !trimmed.isEmpty { inHeader = false }
            bodyLines.append(line)
        }
    }

    let name = meta["name"] ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let description = meta["description"] ?? "Swift script skill"
    let baseDir = (path as NSString).deletingLastPathComponent

    let skill = Skill(
        name: name,
        description: description,
        content: content,
        filePath: path,
        baseDir: baseDir,
        source: source,
        disableModelInvocation: meta["disablemodelinvocation"]?.lowercased() == "true",
        isSwiftScript: true
    )

    return (skill, diagnostics)
}

/// Resolve the user-level skills directory path
public func userSkillsDirectory() -> String {
    let home = NSHomeDirectory()
    return (home as NSString).appendingPathComponent(".swiftpi/skills")
}

/// Resolve the project-level skills directory path
public func projectSkillsDirectory(cwd: String) -> String {
    return (cwd as NSString).appendingPathComponent(".swiftpi/skills")
}

// MARK: - Helpers

/// Parse YAML frontmatter from markdown
private func parseFrontmatter(_ content: String) -> (frontmatter: [String: String], body: String) {
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
            // Remove quotes
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            frontmatter[key] = unquoted
        }
    }

    let body = lines[endIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (frontmatter, body)
}

private func extractFirstLine(_ text: String) -> String {
    let line = text.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    return line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
}

private func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// Enumerate resource files in a skill directory (relative paths, excluding SKILL.md)
private func enumerateResourceFiles(in dir: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return [] }
    var files: [String] = []
    while let relativePath = enumerator.nextObject() as? String {
        // Skip SKILL.md itself, hidden files, and common junk
        if relativePath == "SKILL.md" { continue }
        if (relativePath as NSString).lastPathComponent.hasPrefix(".") { continue }
        let fullPath = (dir as NSString).appendingPathComponent(relativePath)
        if !isDirectory(fullPath) {
            files.append(relativePath)
        }
    }
    return files
}
