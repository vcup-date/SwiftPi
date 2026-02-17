import Foundation
import PiAI

// MARK: - Agent

/// Main agent class — orchestrates the agentic loop with message management and state tracking
@MainActor
public final class Agent: ObservableObject {
    @Published public private(set) var state: AgentState

    private var subscribers: [(id: UUID, handler: (AgentEvent) -> Void)] = []
    private var steeringQueue: [AgentMessage] = []
    private var followUpQueue: [AgentMessage] = []
    private var currentTask: Task<Void, Never>?

    public var steeringMode: DeliveryMode = .all
    public var followUpMode: DeliveryMode = .all
    /// Pre-execution safety check callback. Set by AgentSession to gate dangerous tool calls.
    public var confirmToolExecution: (@Sendable (String, [String: AnyCodable]) async -> ToolPermission)?

    public enum DeliveryMode: Sendable {
        case all
        case oneAtATime
    }

    private let apiKeyManager: APIKeyManager?

    public init(
        model: LLMModel,
        systemPrompt: String = "",
        tools: [AgentTool] = [],
        thinkingLevel: ThinkingLevel = .off,
        apiKeyManager: APIKeyManager? = nil
    ) {
        self.state = AgentState(
            systemPrompt: systemPrompt,
            model: model,
            thinkingLevel: thinkingLevel,
            tools: tools
        )
        self.apiKeyManager = apiKeyManager
    }

    // MARK: - Configuration

    public func setSystemPrompt(_ prompt: String) {
        state.systemPrompt = prompt
    }

    public func setModel(_ model: LLMModel) {
        state.model = model
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        state.thinkingLevel = level
    }

    public func setTools(_ tools: [AgentTool]) {
        state.tools = tools
    }

    // MARK: - Message Management

    public func replaceMessages(_ messages: [AgentMessage]) {
        state.messages = messages
    }

    public func appendMessage(_ message: AgentMessage) {
        state.messages.append(message)
    }

    public func clearMessages() {
        state.messages.removeAll()
    }

    // MARK: - Steering & Follow-Up

    public func steer(_ message: AgentMessage) {
        steeringQueue.append(message)
    }

    public func followUp(_ message: AgentMessage) {
        followUpQueue.append(message)
    }

    public func clearSteeringQueue() {
        steeringQueue.removeAll()
    }

    public func clearFollowUpQueue() {
        followUpQueue.removeAll()
    }

    public func clearAllQueues() {
        steeringQueue.removeAll()
        followUpQueue.removeAll()
    }

    public var hasQueuedMessages: Bool {
        !steeringQueue.isEmpty || !followUpQueue.isEmpty
    }

    // MARK: - Subscriptions

    @discardableResult
    public func subscribe(_ fn: @escaping (AgentEvent) -> Void) -> () -> Void {
        let id = UUID()
        subscribers.append((id: id, handler: fn))
        return { [weak self] in
            self?.subscribers.removeAll { $0.id == id }
        }
    }

    private func emit(_ event: AgentEvent) {
        for subscriber in subscribers {
            subscriber.handler(event)
        }
    }

    // MARK: - Prompting

    /// Send a text prompt and run the agent loop
    public func prompt(_ text: String, images: [ImageContent] = []) async {
        let message = AgentMessage.user(text, images: images)
        await prompt(messages: [message])
    }

    /// Send messages and run the agent loop
    public func prompt(messages: [AgentMessage]) async {
        state.isStreaming = true
        state.error = nil

        let config = makeConfig()
        let context = AgentContext(
            systemPrompt: state.systemPrompt,
            messages: state.messages,
            tools: state.tools
        )

        let eventStream = agentLoop(
            prompts: messages,
            context: context,
            config: config
        )

        await processEvents(eventStream)
    }

    /// Continue from current context (retry, queued messages)
    public func `continue`() async {
        state.isStreaming = true
        state.error = nil

        let config = makeConfig()
        let context = AgentContext(
            systemPrompt: state.systemPrompt,
            messages: state.messages,
            tools: state.tools
        )

        let eventStream = agentLoopContinue(
            context: context,
            config: config
        )

        await processEvents(eventStream)
    }

    /// Abort current streaming
    public func abort() {
        currentTask?.cancel()
        currentTask = nil
        state.isStreaming = false
    }

    /// Reset all state
    public func reset() {
        abort()
        state.messages.removeAll()
        state.error = nil
        state.streamMessage = nil
        state.pendingToolCalls.removeAll()
        steeringQueue.removeAll()
        followUpQueue.removeAll()
    }

    /// Wait for the agent to finish
    public func waitForIdle() async {
        while state.isStreaming {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    // MARK: - Internal

    private func makeConfig() -> AgentLoopConfig {
        let keyManager = apiKeyManager
        var model = state.model

        // Always resolve base URL from selected API key at request time
        if let resolvedUrl = keyManager?.resolveBaseUrl(for: model), !resolvedUrl.isEmpty {
            model.baseUrl = resolvedUrl
        }

        return AgentLoopConfig(
            model: model,
            reasoning: state.thinkingLevel,
            getApiKey: { [weak self] provider in
                guard let self else { return nil }
                // Check API key manager
                if let key = keyManager?.resolveApiKey(for: model) {
                    return key
                }
                return nil
            },
            getSteeringMessages: { [weak self] in
                guard let self else { return [] }
                return await MainActor.run {
                    let messages: [AgentMessage]
                    switch self.steeringMode {
                    case .all:
                        messages = self.steeringQueue
                        self.steeringQueue.removeAll()
                    case .oneAtATime:
                        if let first = self.steeringQueue.first {
                            messages = [first]
                            self.steeringQueue.removeFirst()
                        } else {
                            messages = []
                        }
                    }
                    return messages
                }
            },
            getFollowUpMessages: { [weak self] in
                guard let self else { return [] }
                return await MainActor.run {
                    let messages: [AgentMessage]
                    switch self.followUpMode {
                    case .all:
                        messages = self.followUpQueue
                        self.followUpQueue.removeAll()
                    case .oneAtATime:
                        if let first = self.followUpQueue.first {
                            messages = [first]
                            self.followUpQueue.removeFirst()
                        } else {
                            messages = []
                        }
                    }
                    return messages
                }
            },
            confirmToolExecution: confirmToolExecution
        )
    }

    private func processEvents(_ eventStream: AgentEventStream) async {
        // Buffer messageUpdate to avoid thrashing @Published / SwiftUI on every token.
        // AgentLoop already throttles, but we add a second guard here in case
        // the upstream stream pushes faster than expected.
        var pendingStreamMsg: AssistantMessage?

        for await event in eventStream {
            switch event {
            case .agentStart:
                break
            case .agentEnd(let messages):
                // Flush any pending stream message before finishing
                if pendingStreamMsg != nil {
                    pendingStreamMsg = nil
                    state.streamMessage = nil
                }
                state.messages = messages
                state.isStreaming = false
                state.streamMessage = nil
                state.pendingToolCalls.removeAll()
            case .messageStart(let msg):
                state.streamMessage = .assistant(msg)
            case .messageUpdate(let msg, _):
                // Store for emission but DON'T update @Published here.
                // The AgentSession subscriber will handle UI updates.
                pendingStreamMsg = msg
                state.streamMessage = .assistant(msg)
            case .messageEnd(let msg):
                pendingStreamMsg = nil
                state.streamMessage = nil
                if let err = msg.errorMessage {
                    state.error = err
                }
            case .toolExecutionStart(let id, _, _):
                state.pendingToolCalls.insert(id)
            case .toolExecutionEnd(let id, _, _, _):
                state.pendingToolCalls.remove(id)
            default:
                break
            }
            emit(event)
        }
    }
}
