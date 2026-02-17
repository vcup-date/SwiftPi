import Foundation
import PiAI
import PiAgent

// MARK: - Agent Session

/// Central orchestrator — coordinates agent, session, settings, tools, skills, and extensions
@MainActor
public final class AgentSession: ObservableObject {
    // MARK: - Published State
    @Published public private(set) var isStreaming = false
    @Published public private(set) var currentMessage: AssistantMessage?
    @Published public private(set) var messages: [AgentMessage] = []
    @Published public private(set) var events: [AgentEventRecord] = []
    @Published public private(set) var error: String?
    @Published public private(set) var retryAttempt: Int = 0
    @Published public private(set) var activeToolExecutions: [ActiveToolExecution] = []
    @Published public private(set) var streamingHistory: [StreamingHistoryItem] = []
    @Published public var pendingConfirmation: ToolConfirmation?
    @Published public var acceptAllPermissions = false

    // MARK: - Components
    public let agent: Agent
    public let sessionManager: SessionManager
    public let settingsManager: SettingsManager
    public let apiKeyManager: APIKeyManager
    public let extensionRunner: ExtensionRunner
    public let cwd: String

    // MARK: - Config
    @Published public var skills: [Skill] = []
    @Published public var promptTemplates: [PromptTemplate] = []
    public var systemPromptOverride: String?
    public var appendSystemPrompt: String?
    public var contextFiles: [(path: String, content: String)] = []

    /// All editable prompt sections for the config UI
    public var editablePrompts: EditablePrompts

    // MARK: - Init

    public init(
        cwd: String,
        model: LLMModel? = nil,
        apiKeyManager: APIKeyManager = APIKeyManager(),
        sessionManager: SessionManager? = nil,
        settingsManager: SettingsManager? = nil
    ) {
        let resolvedModel = model ?? LLMModel(
            id: "gpt-4o",
            name: "GPT-4o",
            api: .known(.openaiResponses),
            provider: .known(.openai),
            contextWindow: 128_000,
            maxTokens: 16_384
        )
        self.cwd = cwd
        self.currentModel = resolvedModel
        self.apiKeyManager = apiKeyManager
        self.settingsManager = settingsManager ?? SettingsManager(cwd: cwd)
        self.sessionManager = sessionManager ?? SessionManager.inMemory(cwd: cwd)
        self.extensionRunner = ExtensionRunner()
        self.editablePrompts = EditablePrompts()

        self.agent = Agent(
            model: resolvedModel,
            thinkingLevel: self.settingsManager.defaultThinkingLevel,
            apiKeyManager: apiKeyManager
        )

        // Build tools
        let tools = buildDefaultTools()
        agent.setTools(tools)

        // Load resources
        loadResources()

        // Build system prompt
        rebuildSystemPrompt()

        // Set up tool safety confirmation
        let cwdForSafety = cwd
        agent.confirmToolExecution = { [weak self] toolName, args in
            guard let self else { return .allow }
            let safety = ToolSafety.check(toolName: toolName, args: args, cwd: cwdForSafety)
            switch safety {
            case .safe:
                return .allow
            case .blocked(let reason):
                return .deny(reason: reason)
            case .needsConfirmation(let reason):
                return await self.requestConfirmation(toolName: toolName, args: args, reason: reason)
            }
        }

        // Subscribe to agent events
        _ = agent.subscribe { [weak self] event in
            self?.handleAgentEvent(event)
        }
    }

    // MARK: - Prompt

    /// Send a user message and run the agent
    public func prompt(_ text: String, images: [ImageContent] = []) async {
        // Expand prompt templates
        let expandedText = expandPromptTemplate(text, templates: promptTemplates)

        isStreaming = true
        error = nil

        // Show user message immediately in the UI
        let userMessage = UserMessage(text: expandedText)
        messages.append(.message(.user(userMessage)))
        sessionManager.appendMessage(.user(userMessage))

        // Rebuild system prompt (may include new context)
        rebuildSystemPrompt()

        await agent.prompt(expandedText, images: images)

        isStreaming = false
    }

    /// Clear event log
    public func clearEvents() {
        events.removeAll()
    }

    /// Abort current execution
    public func abort() {
        agent.abort()
        isStreaming = false
    }

    /// Reset and start fresh
    public func reset() {
        agent.reset()
        messages.removeAll()
        events.removeAll()
        error = nil
        currentMessage = nil
        acceptAllPermissions = false
    }

    // MARK: - Model Management

    @Published public private(set) var currentModel: LLMModel

    public var model: LLMModel {
        currentModel
    }

    public func setModel(_ model: LLMModel) {
        currentModel = model
        agent.setModel(model)
        sessionManager.appendModelChange(provider: model.provider.description, modelId: model.id)
        // Persist to settings
        settingsManager.setDefaultModel(model.id)
        settingsManager.setDefaultProvider(model.provider.description)
        settingsManager.setLastModel(model)
    }

    public var thinkingLevel: ThinkingLevel {
        agent.state.thinkingLevel
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        objectWillChange.send()
        agent.setThinkingLevel(level)
        sessionManager.appendThinkingLevelChange(level)
        // Persist to settings
        settingsManager.setDefaultThinkingLevel(level)
    }

    // MARK: - Compaction

    /// Compact the conversation history
    public func compact() async throws {
        let result = try await PiCodingAgent.compact(
            messages: messages,
            model: model,
            contextWindow: model.contextWindow,
            settings: settingsManager.compaction,
            apiKeyManager: apiKeyManager
        )

        sessionManager.appendCompaction(CompactionData(
            summary: result.summary,
            firstKeptEntryId: result.firstKeptEntryId,
            tokensBefore: result.tokensBefore
        ))

        // Rebuild context from session
        let ctx = sessionManager.buildContext()
        agent.replaceMessages(ctx.messages)
        messages = ctx.messages

        addEvent(.init(type: .compaction, message: "Compacted: \(result.tokensBefore) → \(result.tokensAfter) tokens"))
    }

    // MARK: - Session Management

    /// Get session name
    public var sessionName: String? {
        sessionManager.sessionName
    }

    /// Set session name
    public func setSessionName(_ name: String) {
        sessionManager.appendSessionInfo(name: name)
    }

    // MARK: - Internal

    private func buildDefaultTools() -> [AgentTool] {
        var tools: [AgentTool] = [
            BashTool(cwd: cwd).agentTool,
            ReadTool(cwd: cwd).agentTool,
            WriteTool(cwd: cwd).agentTool,
            EditTool(cwd: cwd).agentTool,
            GrepTool(cwd: cwd).agentTool,
            FindTool(cwd: cwd).agentTool,
            LsTool(cwd: cwd).agentTool,
            SwiftTool(cwd: cwd).agentTool,
            UIBuilderTool().agentTool,
            AppleScriptTool().agentTool,
        ]

        // Add extension tools
        tools.append(contentsOf: extensionRunner.allTools)

        return tools
    }

    private func loadResources() {
        // Load skills
        let skillResult = loadSkills(cwd: cwd, skillPaths: settingsManager.skillPaths)
        skills = skillResult.skills

        // Load prompt templates
        promptTemplates = loadPromptTemplates(cwd: cwd, promptPaths: settingsManager.promptPaths)

        // Load extensions
        let extResult = discoverAndLoadExtensions(
            configuredPaths: settingsManager.extensionPaths,
            cwd: cwd
        )
        extensionRunner.addExtensions(extResult.extensions)
    }

    private func rebuildSystemPrompt() {
        let prompt = buildSystemPrompt(options: SystemPromptOptions(
            customPrompt: systemPromptOverride ?? editablePrompts.mainSystemPrompt,
            selectedTools: nil, // Use all
            appendSystemPrompt: appendSystemPrompt,
            cwd: cwd,
            contextFiles: contextFiles,
            skills: skills
        ))
        agent.setSystemPrompt(prompt)
    }

    /// Reload skills from disk
    public func reloadSkills() {
        let skillResult = loadSkills(cwd: cwd, skillPaths: settingsManager.skillPaths)
        skills = skillResult.skills
        rebuildSystemPrompt()
    }

    /// Create a skill using the AI agent
    public func createSkill(description: String, inProject: Bool, useDirectory: Bool) async {
        let targetDir = inProject ? projectSkillsDirectory(cwd: cwd) : userSkillsDirectory()

        // Ensure the directory exists
        try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let skillPrompt: String
        if useDirectory {
            skillPrompt = """
            Create a new directory-style skill in \(targetDir). The user wants: \(description)

            Follow the Claude Agent Skills standard. Create a directory structure like:

            \(targetDir)/<skill-name>/
            ├── SKILL.md          (main instructions with YAML frontmatter)
            ├── <reference>.md    (optional additional docs, referenced from SKILL.md)
            └── scripts/          (optional executable scripts)
                └── <script>.py   (or .swift, .sh — utility scripts)

            SKILL.md MUST have this format:
            ```
            ---
            name: <skill-name>
            description: <Brief description of what this Skill does and when to use it. Include trigger words.>
            ---

            # <Skill Name>

            ## Quick start
            [Core workflow / getting started instructions]

            ## Detailed instructions
            [Step-by-step guidance, best practices, examples]

            ## Additional resources
            [Links to bundled reference files using relative paths, e.g. see [REFERENCE.md](REFERENCE.md)]
            ```

            Rules:
            1. Skill name must be lowercase, alphanumeric with hyphens only (max 64 chars).
            2. Description should explain WHAT it does AND WHEN to use it (max 1024 chars).
            3. Use progressive disclosure: SKILL.md has core instructions, additional .md files for detailed reference.
            4. If the skill needs executable code, put scripts in a scripts/ subdirectory.
            5. Reference additional files with relative paths in SKILL.md so the agent can find them.
            6. Use the write tool to create all files.
            7. Keep SKILL.md focused and under 5000 tokens. Put detailed docs in separate files.
            """
        } else {
            skillPrompt = """
            Create a new skill file in \(targetDir). The user wants: \(description)

            Follow the Claude Agent Skills standard. Create a single .md file with this format:

            ```
            ---
            name: <skill-name>
            description: <Brief description of what this Skill does and when to use it. Include trigger words.>
            ---

            # <Skill Name>

            ## Quick start
            [Core workflow / getting started instructions]

            ## Detailed instructions
            [Step-by-step guidance, best practices, examples]

            ## Examples
            [Concrete examples of using this Skill]
            ```

            Rules:
            1. Skill name must be lowercase, alphanumeric with hyphens only (max 64 chars).
            2. Description should explain WHAT it does AND WHEN to use it (max 1024 chars).
            3. Use the write tool to create the file in: \(targetDir)
            4. Keep the skill focused and concise.
            """
        }

        await prompt(skillPrompt)

        // Reload skills after creation
        reloadSkills()
    }

    /// Rebuild system prompt from editable prompts
    public func applyEditablePrompts() {
        rebuildSystemPrompt()
        // Also update tool descriptions if customized
        let tools = buildDefaultTools()
        agent.setTools(tools)
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        switch event {
        case .agentEnd(let msgs):
            messages = msgs
            activeToolExecutions.removeAll()
            streamingHistory.removeAll()
            // Persist assistant messages
            for msg in msgs {
                if let message = msg.asMessage {
                    switch message {
                    case .assistant, .toolResult:
                        sessionManager.appendMessage(message)
                    default:
                        break
                    }
                }
            }

        case .messageStart(let msg):
            currentMessage = msg
            addEvent(.init(type: .messageStart, message: "Assistant started responding"))

        case .messageUpdate(let msg, _):
            currentMessage = msg

        case .messageEnd(let msg):
            currentMessage = nil
            // Keep completed message in streaming history so it stays visible
            streamingHistory.append(.assistantMessage(msg))
            if let err = msg.errorMessage {
                error = err
                addEvent(.init(type: .error, message: err))

                // Check for retryable errors
                if settingsManager.isRetryEnabled && isRetryableError(err) {
                    Task { await autoRetry() }
                }
            } else {
                addEvent(.init(type: .messageEnd, message: "Assistant finished (tokens: \(msg.usage?.totalTokens ?? 0))"))
            }

        case .toolExecutionStart(let id, let name, let args):
            activeToolExecutions.append(ActiveToolExecution(
                id: id, name: name, args: args, startTime: Date()
            ))
            addEvent(.init(
                type: .toolStart,
                message: "Tool: \(name)",
                details: "Args: \(args.map { "\($0.key): \($0.value)" }.joined(separator: ", "))"
            ))

        case .toolExecutionUpdate(let id, _, let result):
            let text = resultText(result)
            if let idx = activeToolExecutions.firstIndex(where: { $0.id == id }) {
                // Cap tool output to prevent unbounded growth during streaming
                let maxOutputLen = 100_000
                if activeToolExecutions[idx].output.count + text.count > maxOutputLen {
                    activeToolExecutions[idx].output = String(activeToolExecutions[idx].output.suffix(maxOutputLen / 2)) + text
                } else {
                    activeToolExecutions[idx].output += text
                }
            }
            // Don't create event records for every tool output chunk — too many

        case .toolExecutionEnd(let id, let name, let result, let isError):
            let text = resultText(result)
            if let idx = activeToolExecutions.firstIndex(where: { $0.id == id }) {
                activeToolExecutions[idx].output = text
                activeToolExecutions[idx].isComplete = true
                activeToolExecutions[idx].isError = isError
            }
            addEvent(.init(
                type: isError ? .toolError : .toolEnd,
                message: "[\(name)] \(isError ? "Error" : "Done")",
                details: String(text.prefix(500))
            ))

        case .turnStart:
            addEvent(.init(type: .turnStart, message: "Turn started"))

        case .turnEnd(_, let results):
            // Move completed tool executions to history, then clear
            for tool in activeToolExecutions where tool.isComplete {
                streamingHistory.append(.toolExecution(tool))
            }
            activeToolExecutions.removeAll()
            // Cap streaming history to prevent unbounded growth during long multi-turn runs
            let maxStreamingHistory = 30
            if streamingHistory.count > maxStreamingHistory {
                streamingHistory.removeFirst(streamingHistory.count - maxStreamingHistory)
            }
            addEvent(.init(type: .turnEnd, message: "Turn ended (\(results.count) tool results)"))

        default:
            break
        }
    }

    private func resultText(_ result: AgentToolResult) -> String {
        result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined()
    }

    private static let maxEvents = 500

    private func addEvent(_ event: AgentEventRecord) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    private func isRetryableError(_ error: String) -> Bool {
        let retryable = ["overloaded", "rate limit", "429", "529", "503", "500"]
        return retryable.contains { error.lowercased().contains($0) }
    }

    private func autoRetry() async {
        let maxRetries = settingsManager.retry.maxRetries ?? 3
        guard retryAttempt < maxRetries else { return }

        retryAttempt += 1
        let baseDelay = settingsManager.retry.baseDelayMs ?? 2000
        let delay = baseDelay * Int(pow(2.0, Double(retryAttempt - 1)))
        let cappedDelay = min(delay, settingsManager.retry.maxDelayMs ?? 60000)

        addEvent(.init(type: .retry, message: "Retrying (\(retryAttempt)/\(maxRetries)) in \(cappedDelay)ms"))

        try? await Task.sleep(nanoseconds: UInt64(cappedDelay) * 1_000_000)

        await agent.continue()
        retryAttempt = 0
    }

    // MARK: - Tool Safety Confirmation

    /// Request user confirmation for a dangerous tool call. Suspends until user responds.
    private func requestConfirmation(toolName: String, args: [String: AnyCodable], reason: String) async -> ToolPermission {
        // If user already chose "Accept All", skip confirmation
        if acceptAllPermissions { return .allow }

        await MainActor.run {
            let confirmation = ToolConfirmation(
                toolName: toolName,
                args: args,
                reason: reason
            )
            self.pendingConfirmation = confirmation
        }

        // Wait for user to respond
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
            let result = await MainActor.run { self.pendingConfirmation }
            guard let current = result else {
                // Confirmation was cleared — denied
                return .deny(reason: "User denied: \(reason)")
            }
            if let response = current.response {
                let didAcceptAll = current.didAcceptAll
                await MainActor.run {
                    self.pendingConfirmation = nil
                    if didAcceptAll { self.acceptAllPermissions = true }
                }
                return response ? .allow : .deny(reason: "User denied: \(reason)")
            }
        }
    }
}

// MARK: - Tool Confirmation

/// Pending confirmation request shown to the user
public class ToolConfirmation: ObservableObject, Identifiable {
    public let id = UUID()
    public let toolName: String
    public let args: [String: AnyCodable]
    public let reason: String
    public var response: Bool? = nil
    public var didAcceptAll: Bool = false

    public init(toolName: String, args: [String: AnyCodable], reason: String) {
        self.toolName = toolName
        self.args = args
        self.reason = reason
    }

    public func allow() { response = true }
    public func deny() { response = false }
    public func acceptAll() { didAcceptAll = true; response = true }
}

// MARK: - Event Record

/// A recorded agent event for the UI timeline
public struct AgentEventRecord: Identifiable, Sendable {
    public let id = UUID()
    public var type: EventType
    public var message: String
    public var details: String?
    public var timestamp: Date

    public enum EventType: String, Sendable {
        case messageStart, messageEnd
        case toolStart, toolUpdate, toolEnd, toolError
        case turnStart, turnEnd
        case compaction, retry, error
        case info
    }

    public init(type: EventType, message: String, details: String? = nil, timestamp: Date = Date()) {
        self.type = type
        self.message = message
        self.details = details
        self.timestamp = timestamp
    }
}

// MARK: - Active Tool Execution

/// Tracks a tool execution in progress for the UI
public struct ActiveToolExecution: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let args: [String: AnyCodable]
    public var output: String = ""
    public var isComplete: Bool = false
    public var isError: Bool = false
    public let startTime: Date

    public init(id: String, name: String, args: [String: AnyCodable], startTime: Date = Date()) {
        self.id = id
        self.name = name
        self.args = args
        self.startTime = startTime
    }

    /// Get a specific arg as String
    public func arg(_ key: String) -> String? {
        if let val = args[key] {
            if let s = val.value as? String { return s }
            return "\(val.value)"
        }
        return nil
    }
}

// MARK: - Streaming History Item

/// A completed item from a previous turn, kept visible during streaming
public enum StreamingHistoryItem: Identifiable {
    case assistantMessage(AssistantMessage)
    case toolExecution(ActiveToolExecution)

    public var id: String {
        switch self {
        case .assistantMessage(let msg): return "msg-\(msg.id)"
        case .toolExecution(let tool): return "tool-\(tool.id)"
        }
    }
}

// MARK: - Editable Prompts

/// All prompt sections that can be edited in the config UI
public struct EditablePrompts: Sendable {
    /// Main system prompt (nil = use default builder)
    public var mainSystemPrompt: String?

    /// Per-tool descriptions (overrides)
    public var toolDescriptions: [String: String] = [:]

    /// Additional context to append
    public var additionalContext: String?

    /// Custom guidelines
    public var guidelines: String?

    public init() {}
}
