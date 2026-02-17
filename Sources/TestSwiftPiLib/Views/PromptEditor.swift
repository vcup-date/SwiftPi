import SwiftUI
import PiAI
import PiAgent
import PiCodingAgent

// MARK: - Prompt Editor

public struct PromptEditor: View {
    @ObservedObject var session: AgentSession
    @State private var selectedSection: PromptSection = .systemPrompt
    @State private var editedText = ""

    public init(session: AgentSession) {
        self.session = session
    }

    enum PromptSection: String, CaseIterable, Identifiable {
        case systemPrompt = "System Prompt"
        case guidelines = "Guidelines"
        case toolBash = "Tool: Bash"
        case toolRead = "Tool: Read"
        case toolWrite = "Tool: Write"
        case toolEdit = "Tool: Edit"
        case toolGrep = "Tool: Grep"
        case toolFind = "Tool: Find"
        case toolLs = "Tool: Ls"
        case additionalContext = "Additional Context"

        var id: String { rawValue }
    }

    public var body: some View {
        HSplitView {
            // Section list
            List(PromptSection.allCases, selection: $selectedSection) { section in
                HStack {
                    Image(systemName: iconForSection(section))
                        .frame(width: 20)
                    Text(section.rawValue)
                        .font(.caption)
                }
                .tag(section)
            }
            .frame(minWidth: 150, maxWidth: 200)
            .onChange(of: selectedSection) {
                loadSection(selectedSection)
            }

            // Editor
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(selectedSection.rawValue)
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        resetSection(selectedSection)
                    }
                    .font(.caption)
                    Button("Apply") {
                        saveSection(selectedSection, text: editedText)
                        session.applyEditablePrompts()
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                }

                Text(descriptionForSection(selectedSection))
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $editedText)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
            }
            .padding()
        }
        .onAppear {
            loadSection(selectedSection)
        }
    }

    private func loadSection(_ section: PromptSection) {
        switch section {
        case .systemPrompt:
            editedText = session.editablePrompts.mainSystemPrompt ?? buildSystemPrompt(options: SystemPromptOptions(cwd: session.cwd, skills: session.skills))
        case .guidelines:
            editedText = session.editablePrompts.guidelines ?? defaultGuidelines
        case .additionalContext:
            editedText = session.editablePrompts.additionalContext ?? ""
        default:
            let toolName = toolNameForSection(section)
            editedText = session.editablePrompts.toolDescriptions[toolName] ?? defaultToolDescription(toolName)
        }
    }

    private func saveSection(_ section: PromptSection, text: String) {
        switch section {
        case .systemPrompt:
            session.editablePrompts.mainSystemPrompt = text
        case .guidelines:
            session.editablePrompts.guidelines = text
        case .additionalContext:
            session.editablePrompts.additionalContext = text.isEmpty ? nil : text
            session.appendSystemPrompt = text.isEmpty ? nil : text
        default:
            let toolName = toolNameForSection(section)
            session.editablePrompts.toolDescriptions[toolName] = text
        }
    }

    private func resetSection(_ section: PromptSection) {
        switch section {
        case .systemPrompt:
            session.editablePrompts.mainSystemPrompt = nil
            loadSection(section)
        case .guidelines:
            session.editablePrompts.guidelines = nil
            editedText = defaultGuidelines
        case .additionalContext:
            session.editablePrompts.additionalContext = nil
            editedText = ""
        default:
            let toolName = toolNameForSection(section)
            session.editablePrompts.toolDescriptions.removeValue(forKey: toolName)
            editedText = defaultToolDescription(toolName)
        }
    }

    private func toolNameForSection(_ section: PromptSection) -> String {
        switch section {
        case .toolBash: return "bash"
        case .toolRead: return "read"
        case .toolWrite: return "write"
        case .toolEdit: return "edit"
        case .toolGrep: return "grep"
        case .toolFind: return "find"
        case .toolLs: return "ls"
        default: return ""
        }
    }

    private func iconForSection(_ section: PromptSection) -> String {
        switch section {
        case .systemPrompt: return "brain"
        case .guidelines: return "list.bullet"
        case .additionalContext: return "doc.append"
        default: return "wrench"
        }
    }

    private func descriptionForSection(_ section: PromptSection) -> String {
        switch section {
        case .systemPrompt: return "The main system prompt that defines the agent's behavior and capabilities."
        case .guidelines: return "Guidelines for the agent to follow when using tools and interacting."
        case .additionalContext: return "Additional context appended to the system prompt. Use for project-specific instructions."
        default: return "Description for the \(toolNameForSection(section)) tool as shown to the LLM."
        }
    }

    private var defaultGuidelines: String {
        """
        - Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)
        - Use read to examine files before editing. You must use this tool instead of cat or sed.
        - Use edit for precise changes (old text must match exactly)
        - Use write only for new files or complete rewrites
        - When summarizing your actions, output plain text directly - do NOT use cat or bash to display what you did
        - Be concise in your responses
        - Show file paths clearly when working with files
        """
    }

    private func defaultToolDescription(_ toolName: String) -> String {
        switch toolName {
        case "bash": return "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds."
        case "read": return "Read the contents of a file. Supports text files and images (jpg, png, gif, webp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete."
        case "write": return "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories."
        case "edit": return "Edit a file by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits."
        case "grep": return "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars."
        case "find": return "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first)."
        case "ls": return "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first)."
        default: return ""
        }
    }
}
