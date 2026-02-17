import SwiftUI
import PiAI
import PiAgent
import PiCodingAgent

// MARK: - Chat View

public struct ChatView: View {
    @ObservedObject var session: AgentSession
    @State private var inputText = ""
    @State private var autoScroll = true
    @FocusState private var inputFocused: Bool

    public init(session: AgentSession) {
        self.session = session
    }

    /// Combined scroll trigger — incremented whenever content changes
    private var scrollTrigger: Int {
        session.messages.count
        + (session.currentMessage?.textContent.count ?? 0)
        + (session.currentMessage?.thinkingContent.count ?? 0)
        + session.activeToolExecutions.count
        + session.streamingHistory.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }

                        // Streaming: accumulated history + current message + active tools
                        if session.isStreaming {
                            StreamingSection(
                                history: session.streamingHistory,
                                message: session.currentMessage,
                                activeTools: session.activeToolExecutions
                            )
                            .id("streaming")
                        }

                        // Error
                        if let error = session.error {
                            ErrorBanner(message: error)
                                .id("error")
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: scrollTrigger) {
                    if autoScroll {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Working directory indicator
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(session.cwd)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if session.acceptAllPermissions {
                    Spacer()
                    Text("Accept All")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor).opacity(0.5))

            // Safety confirmation banner
            if let confirmation = session.pendingConfirmation {
                ToolConfirmationBanner(confirmation: confirmation)
            }

            // Input area
            inputArea
        }
        .onAppear {
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .uiBuilderRender)) { notification in
            if let node = notification.userInfo?["node"] as? UINode,
               let title = notification.userInfo?["title"] as? String {
                UIPreviewWindow.shared.show(node: node, title: title)
            }
        }
    }

    private var inputArea: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($inputFocused)
                .onSubmit {
                    if !inputText.isEmpty && !session.isStreaming {
                        sendMessage()
                    }
                }
                .padding(10)
                .background(Color(.textBackgroundColor).opacity(0.5))
                .cornerRadius(8)

            if session.isStreaming {
                Button(action: { session.abort() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(inputText.isEmpty ? .gray : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        Task {
            await session.prompt(text)
        }
    }
}

// MARK: - Message Row

struct MessageRow: View {
    let message: AgentMessage

    var body: some View {
        switch message {
        case .message(let msg):
            switch msg {
            case .user(let m):
                UserBubble(text: m.textContent)
            case .assistant(let m):
                AssistantBubble(message: m)
            case .toolResult(let m):
                ToolResultCard(result: m)
            }
        case .custom(let m):
            HStack {
                Text("[\(m.type)]")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - User Bubble

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .textSelection(.enabled)
                .padding(12)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(12)
                .frame(maxWidth: 600, alignment: .trailing)
        }
    }
}

// MARK: - Assistant Bubble

struct AssistantBubble: View {
    let message: AssistantMessage
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thinking (collapsible)
            if !message.thinkingContent.isEmpty {
                ThinkingBlock(content: message.thinkingContent, isStreaming: false)
            }

            // Text content
            if !message.textContent.isEmpty {
                MarkdownText(text: message.textContent)
            }

            // Tool calls (compact view for completed messages)
            ForEach(message.toolCalls, id: \.id) { toolCall in
                ToolCallCard(toolCall: toolCall)
            }

            // Usage info
            if let usage = message.usage {
                HStack(spacing: 8) {
                    Text("\(usage.totalTokens) tokens")
                    if usage.cost.total > 0 {
                        Text("$\(String(format: "%.4f", usage.cost.total))")
                    }
                    if let model = message.model {
                        Text(model)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streaming Section

/// Shows accumulated history from previous turns + current streaming message + active tools
struct StreamingSection: View {
    let history: [StreamingHistoryItem]
    let message: AssistantMessage?
    let activeTools: [ActiveToolExecution]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Previous turns (thinking, text, tool executions) — stacked
            ForEach(history) { item in
                switch item {
                case .assistantMessage(let msg):
                    CompletedAssistantBlock(message: msg)
                case .toolExecution(let tool):
                    ActiveToolCard(tool: tool)
                }
            }

            // Current streaming message
            if let message {
                // Thinking in progress
                if !message.thinkingContent.isEmpty {
                    ThinkingBlock(content: message.thinkingContent, isStreaming: true)
                }

                // Text streaming
                if !message.textContent.isEmpty {
                    MarkdownText(text: message.textContent)
                }

                // Tool calls being built by LLM (args streaming)
                ForEach(message.toolCalls, id: \.id) { toolCall in
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Image(systemName: toolIcon(toolCall.name))
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(toolCall.name)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                    .padding(6)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(6)
                }
            }

            // Active tool executions (running tools with live output)
            ForEach(activeTools) { tool in
                ActiveToolCard(tool: tool)
            }

            // Initial loading state
            if message == nil && activeTools.isEmpty && history.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Thinking...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Completed Assistant Block (from a previous turn, shown inline during streaming)

struct CompletedAssistantBlock: View {
    let message: AssistantMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.thinkingContent.isEmpty {
                ThinkingBlock(content: message.thinkingContent, isStreaming: false)
            }
            if !message.textContent.isEmpty {
                MarkdownText(text: message.textContent)
            }
            ForEach(message.toolCalls, id: \.id) { toolCall in
                ToolCallCard(toolCall: toolCall)
            }
        }
    }
}

// MARK: - Thinking Block

struct ThinkingBlock: View {
    let content: String
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.orange)

                    if isStreaming {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 10, height: 10)
                    }

                    Text(isStreaming ? "Thinking..." : "Thinking")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)

                    Spacer()

                    Text("\(content.count) chars")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Content (expanded or streaming)
            if expanded || isStreaming {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(isStreaming ? 20 : nil)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Tool Call Card (completed, in assistant message)

struct ToolCallCard: View {
    let toolCall: ToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Image(systemName: toolIcon(toolCall.name))
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(toolCall.name)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)

                    // Show key arg preview
                    if let preview = toolArgPreview(toolCall) {
                        Text(preview)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if expanded {
                // Show all args
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(toolCall.arguments.keys.sorted()), id: \.self) { key in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\(key):")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(minWidth: 60, alignment: .trailing)
                            Text(String(describing: toolCall.arguments[key]?.value ?? ""))
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(5)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
                .background(Color(.controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
                .padding(.top, 4)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Active Tool Card (executing, with live output)

struct ActiveToolCard: View {
    let tool: ActiveToolExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                if tool.isComplete {
                    Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(tool.isError ? .red : .green)
                } else {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }

                Image(systemName: toolIcon(tool.name))
                    .font(.caption)
                    .foregroundColor(tool.isError ? .red : .blue)

                Text(tool.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)

                Spacer()

                let elapsed = Date().timeIntervalSince(tool.startTime)
                if !tool.isComplete && elapsed > 1 {
                    Text(String(format: "%.1fs", elapsed))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Tool-specific content
            toolBody
        }
        .padding(10)
        .background(tool.isError ? Color.red.opacity(0.05) : Color(.controlBackgroundColor).opacity(0.3))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    @ViewBuilder
    private var toolBody: some View {
        switch tool.name {
        case "bash":
            bashBody
        case "read":
            fileBody(label: "Reading", pathKey: "path")
        case "write":
            fileBody(label: "Writing", pathKey: "path")
        case "edit":
            editBody
        case "grep":
            grepBody
        case "find":
            findBody
        case "ls":
            fileBody(label: "Listing", pathKey: "path")
        default:
            defaultBody
        }
    }

    private var bashBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Command
            if let cmd = tool.arg("command") {
                HStack(alignment: .top, spacing: 4) {
                    Text(">")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                    Text(cmd)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(4)
            }
            // Output
            if !tool.output.isEmpty {
                ConsoleOutput(text: tool.output, isError: tool.isError)
            }
        }
    }

    private func fileBody(label: String, pathKey: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = tool.arg(pathKey) {
                Text("\(label): \(path)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !tool.output.isEmpty {
                ConsoleOutput(text: tool.output, isError: tool.isError, maxLines: 10)
            }
        }
    }

    private var editBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = tool.arg("path") {
                Text("Editing: \(path)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let old = tool.arg("oldText"), !old.isEmpty {
                Text(old)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.05))
                    .cornerRadius(4)
            }
            if let new = tool.arg("newText"), !new.isEmpty {
                Text(new)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(3)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.05))
                    .cornerRadius(4)
            }
            if !tool.output.isEmpty {
                ConsoleOutput(text: tool.output, isError: tool.isError, maxLines: 3)
            }
        }
    }

    private var grepBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pattern = tool.arg("pattern") {
                HStack(spacing: 4) {
                    Text("Pattern:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(pattern)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
            }
            if let path = tool.arg("path") {
                HStack(spacing: 4) {
                    Text("In:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !tool.output.isEmpty {
                ConsoleOutput(text: tool.output, isError: tool.isError)
            }
        }
    }

    private var findBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pattern = tool.arg("pattern") {
                HStack(spacing: 4) {
                    Text("Pattern:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(pattern)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
            }
            if !tool.output.isEmpty {
                ConsoleOutput(text: tool.output, isError: tool.isError)
            }
        }
    }

    private var defaultBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Show key args
            ForEach(Array(tool.args.keys.sorted().prefix(3)), id: \.self) { key in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(describing: tool.args[key]?.value ?? ""))
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                }
            }
            if !tool.output.isEmpty {
                ConsoleOutput(text: tool.output, isError: tool.isError)
            }
        }
    }
}

// MARK: - Console Output

struct ConsoleOutput: View {
    let text: String
    var isError: Bool = false
    var maxLines: Int = 15

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(isError ? .red : .primary)
            .lineLimit(maxLines)
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(4)
    }
}

// MARK: - Tool Result Card (completed tool result in message history)

struct ToolResultCard: View {
    let result: ToolResultMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(result.isError ? .red : .green)
                    Text(result.toolName)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)

                    Spacer()

                    // Output size hint
                    let charCount = result.textContent.count
                    if charCount > 0 {
                        Text("\(charCount) chars")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(result.textContent)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .background(result.isError ? Color.red.opacity(0.05) : Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(8)
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.red)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Tool Confirmation Banner

struct ToolConfirmationBanner: View {
    @ObservedObject var confirmation: ToolConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.title3)
                Text("Confirmation Required")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
            }

            // Reason
            Text(confirmation.reason)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            // Tool + args preview
            HStack(spacing: 4) {
                Image(systemName: toolIcon(confirmation.toolName))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(confirmation.toolName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if let cmd = confirmation.args["command"]?.stringValue {
                Text(cmd)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(3)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)
            } else if let path = confirmation.args["path"]?.stringValue {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: { confirmation.allow() }) {
                    Label("Allow", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

                Button(action: { confirmation.acceptAll() }) {
                    Label("Accept All", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)

                Button(action: { confirmation.deny() }) {
                    Label("Deny", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Markdown Text (simplified)

struct MarkdownText: View {
    let text: String

    var body: some View {
        let key: LocalizedStringKey = LocalizedStringKey(text)
        Text(key)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Helpers

/// Icon for each tool type
private func toolIcon(_ name: String) -> String {
    switch name {
    case "bash": return "terminal"
    case "read": return "doc.text"
    case "write": return "doc.text.fill"
    case "edit": return "pencil"
    case "grep": return "magnifyingglass"
    case "find": return "folder.badge.magnifyingglass" // Fixed: use valid SF Symbol
    case "ls": return "list.bullet"
    case "swift": return "swift"
    case "ui": return "paintbrush.pointed"
    case "applescript": return "scroll"
    default: return "wrench"
    }
}

/// Preview string for a tool call's key argument
private func toolArgPreview(_ toolCall: ToolCall) -> String? {
    let args = toolCall.arguments
    // Show the most relevant arg for each tool
    if let cmd = args["command"]?.value as? String {
        return String(cmd.prefix(60))
    }
    if let path = args["path"]?.value as? String {
        return path
    }
    if let pattern = args["pattern"]?.value as? String {
        return "pattern: \(pattern)"
    }
    return nil
}
