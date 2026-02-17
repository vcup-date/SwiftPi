import Foundation
import PiAI

// MARK: - System Prompt Builder

/// Options for building the system prompt
public struct SystemPromptOptions: Sendable {
    public var customPrompt: String?
    public var selectedTools: [String]?
    public var appendSystemPrompt: String?
    public var cwd: String?
    public var contextFiles: [(path: String, content: String)]
    public var skills: [Skill]

    public init(
        customPrompt: String? = nil,
        selectedTools: [String]? = nil,
        appendSystemPrompt: String? = nil,
        cwd: String? = nil,
        contextFiles: [(path: String, content: String)] = [],
        skills: [Skill] = []
    ) {
        self.customPrompt = customPrompt
        self.selectedTools = selectedTools
        self.appendSystemPrompt = appendSystemPrompt
        self.cwd = cwd
        self.contextFiles = contextFiles
        self.skills = skills
    }
}

/// Build the system prompt for the coding agent
public func buildSystemPrompt(options: SystemPromptOptions = SystemPromptOptions()) -> String {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath

    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .full
    dateFormatter.timeStyle = .medium
    dateFormatter.locale = Locale(identifier: "en_US")
    let dateTime = dateFormatter.string(from: Date())

    let appendSection = options.appendSystemPrompt.map { "\n\n\($0)" } ?? ""

    // If custom prompt provided, use it with context/skills/date appended
    if let custom = options.customPrompt {
        var prompt = custom

        if !appendSection.isEmpty {
            prompt += appendSection
        }

        // Append project context files
        if !options.contextFiles.isEmpty {
            prompt += "\n\n# Project Context\n\n"
            prompt += "Project-specific instructions and guidelines:\n\n"
            for file in options.contextFiles {
                prompt += "## \(file.path)\n\n\(file.content)\n\n"
            }
        }

        // Append skills section (only if read tool is available)
        let customPromptHasRead = options.selectedTools == nil || (options.selectedTools?.contains("read") ?? false)
        if customPromptHasRead && !options.skills.isEmpty {
            prompt += formatSkillsForPrompt(options.skills)
        }

        // Add date/time and working directory last
        prompt += "\nCurrent date and time: \(dateTime)"
        prompt += "\nCurrent working directory: \(resolvedCwd)"

        return prompt
    }

    let selectedTools = options.selectedTools ?? ["read", "bash", "edit", "write", "grep", "find", "ls"]

    // Build tools list based on selected tools (only built-in tools with known descriptions)
    let knownDescriptions = toolDescriptionsMap()
    let tools = selectedTools.filter { knownDescriptions[$0] != nil }
    let toolsList = tools.isEmpty ? "(none)" : tools.map { "- \($0): \(knownDescriptions[$0]!)" }.joined(separator: "\n")

    // Build guidelines based on which tools are actually available
    let guidelines = toolGuidelines(for: tools)

    var prompt = """
    You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

    Available tools:
    \(toolsList)

    In addition to the tools above, you may have access to other custom tools depending on the project.

    Guidelines:
    \(guidelines)
    """

    if !appendSection.isEmpty {
        prompt += appendSection
    }

    // Append project context files
    if !options.contextFiles.isEmpty {
        prompt += "\n\n# Project Context\n\n"
        prompt += "Project-specific instructions and guidelines:\n\n"
        for file in options.contextFiles {
            prompt += "## \(file.path)\n\n\(file.content)\n\n"
        }
    }

    // Append skills section (only if read tool is available)
    let hasRead = tools.contains("read")
    if hasRead && !options.skills.isEmpty {
        prompt += formatSkillsForPrompt(options.skills)
    }

    // Add date/time and working directory last
    prompt += "\nCurrent date and time: \(dateTime)"
    prompt += "\nCurrent working directory: \(resolvedCwd)"

    return prompt
}

// MARK: - Tool Descriptions

/// Tool descriptions map matching the TypeScript original exactly
private func toolDescriptionsMap() -> [String: String] {
    return [
        "read": "Read file contents",
        "bash": "Execute bash commands (ls, grep, find, etc.)",
        "edit": "Make surgical edits to files (find exact text and replace)",
        "write": "Create or overwrite files",
        "grep": "Search file contents for patterns (respects .gitignore)",
        "find": "Find files by glob pattern (respects .gitignore)",
        "ls": "List directory contents",
    ]
}

private func toolGuidelines(for tools: [String]) -> String {
    var guidelinesList: [String] = []

    let hasBash = tools.contains("bash")
    let hasEdit = tools.contains("edit")
    let hasWrite = tools.contains("write")
    let hasGrep = tools.contains("grep")
    let hasFind = tools.contains("find")
    let hasLs = tools.contains("ls")
    let hasRead = tools.contains("read")

    // File exploration guidelines
    if hasBash && !hasGrep && !hasFind && !hasLs {
        guidelinesList.append("Use bash for file operations like ls, rg, find")
    } else if hasBash && (hasGrep || hasFind || hasLs) {
        guidelinesList.append("Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)")
    }

    // Read before edit guideline
    if hasRead && hasEdit {
        guidelinesList.append("Use read to examine files before editing. You must use this tool instead of cat or sed.")
    }

    // Edit guideline
    if hasEdit {
        guidelinesList.append("Use edit for precise changes (old text must match exactly)")
    }

    // Write guideline
    if hasWrite {
        guidelinesList.append("Use write only for new files or complete rewrites")
    }

    // Output guideline (only when actually writing or executing)
    if hasEdit || hasWrite {
        guidelinesList.append("When summarizing your actions, output plain text directly - do NOT use cat or bash to display what you did")
    }

    // Always include these
    guidelinesList.append("Be concise in your responses")
    guidelinesList.append("Show file paths clearly when working with files")

    return guidelinesList.map { "- \($0)" }.joined(separator: "\n")
}
