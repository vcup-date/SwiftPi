import Foundation
import PiAI

// MARK: - Agent Message

/// Agent message — wraps PiAI Message plus custom application messages
public enum AgentMessage: Sendable, Identifiable {
    case message(Message)
    case custom(CustomAgentMessage)

    public var id: String {
        switch self {
        case .message(let m): return m.id
        case .custom(let m): return m.id
        }
    }

    /// Convert to LLM Message (returns nil for custom messages)
    public var asMessage: Message? {
        if case .message(let m) = self { return m }
        return nil
    }

    /// Quick constructors
    public static func user(_ text: String, images: [ImageContent] = []) -> AgentMessage {
        if images.isEmpty {
            return .message(.user(UserMessage(text: text)))
        }
        var blocks: [UserContentBlock] = [.text(TextContent(text: text))]
        blocks.append(contentsOf: images.map { .image($0) })
        return .message(.user(UserMessage(content: .blocks(blocks))))
    }

    public static func assistant(_ message: AssistantMessage) -> AgentMessage {
        .message(.assistant(message))
    }

    public static func toolResult(_ result: ToolResultMessage) -> AgentMessage {
        .message(.toolResult(result))
    }
}

/// Custom agent message for app-specific message types
public struct CustomAgentMessage: Sendable, Identifiable {
    public let id: String
    public var type: String
    public var data: [String: AnyCodable]
    public var timestamp: Date

    public init(id: String = UUID().uuidString, type: String, data: [String: AnyCodable] = [:], timestamp: Date = Date()) {
        self.id = id
        self.type = type
        self.data = data
        self.timestamp = timestamp
    }
}

// MARK: - Agent Tool

/// A tool that the agent can use — includes execute function
public struct AgentTool: Sendable {
    public let name: String
    public let label: String
    public let description: String
    public let parameters: JSONSchema
    public let execute: @Sendable (String, [String: AnyCodable], AgentToolUpdateCallback?) async throws -> AgentToolResult

    public init(
        name: String,
        label: String,
        description: String,
        parameters: JSONSchema,
        execute: @escaping @Sendable (String, [String: AnyCodable], AgentToolUpdateCallback?) async throws -> AgentToolResult
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    /// Convert to ToolDefinition for LLM
    public var toolDefinition: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }
}

/// Result from tool execution
public struct AgentToolResult: Sendable {
    public var content: [ToolResultContentBlock]
    public var details: [String: AnyCodable]

    public init(content: [ToolResultContentBlock] = [], details: [String: AnyCodable] = [:]) {
        self.content = content
        self.details = details
    }

    /// Quick text result
    public static func text(_ text: String, details: [String: AnyCodable] = [:]) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: text))],
            details: details
        )
    }

    /// Error result
    public static func error(_ message: String) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: "Error: \(message)"))],
            details: [:]
        )
    }
}

/// Callback for streaming partial tool updates
public typealias AgentToolUpdateCallback = @Sendable (AgentToolResult) -> Void

// MARK: - Agent State

/// Full agent state
public struct AgentState: Sendable {
    public var systemPrompt: String
    public var model: LLMModel
    public var thinkingLevel: ThinkingLevel
    public var tools: [AgentTool]
    public var messages: [AgentMessage]
    public var isStreaming: Bool
    public var streamMessage: AgentMessage?
    public var pendingToolCalls: Set<String>
    public var error: String?

    public init(
        systemPrompt: String = "",
        model: LLMModel,
        thinkingLevel: ThinkingLevel = .off,
        tools: [AgentTool] = [],
        messages: [AgentMessage] = []
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
        self.isStreaming = false
        self.streamMessage = nil
        self.pendingToolCalls = []
        self.error = nil
    }
}

// MARK: - Agent Context

/// Context passed to the agent loop
public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [AgentMessage]
    public var tools: [AgentTool]

    public init(systemPrompt: String = "", messages: [AgentMessage] = [], tools: [AgentTool] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

// MARK: - Agent Loop Config

/// Result of a tool safety check
public enum ToolPermission: Sendable {
    case allow
    case deny(reason: String)
}

/// Configuration for the agent loop
public struct AgentLoopConfig: Sendable {
    public var model: LLMModel
    public var reasoning: ThinkingLevel
    public var thinkingBudgets: ThinkingBudgets?
    /// Maximum turns before the agent loop stops. Prevents runaway memory growth.
    public var maxTurns: Int?
    public var convertToLlm: @Sendable ([AgentMessage]) -> [Message]
    public var transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?
    public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?
    /// Called before executing a tool. Return .allow to proceed, .deny to block.
    /// Parameters: toolName, arguments
    public var confirmToolExecution: (@Sendable (String, [String: AnyCodable]) async -> ToolPermission)?

    public init(
        model: LLMModel,
        reasoning: ThinkingLevel = .off,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxTurns: Int? = nil,
        convertToLlm: @escaping @Sendable ([AgentMessage]) -> [Message] = defaultConvertToLlm,
        transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil,
        confirmToolExecution: (@Sendable (String, [String: AnyCodable]) async -> ToolPermission)? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.maxTurns = maxTurns
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.getApiKey = getApiKey
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.confirmToolExecution = confirmToolExecution
    }
}

/// Default conversion: just extract Message from AgentMessage, skip custom
public func defaultConvertToLlm(_ messages: [AgentMessage]) -> [Message] {
    messages.compactMap { $0.asMessage }
}
