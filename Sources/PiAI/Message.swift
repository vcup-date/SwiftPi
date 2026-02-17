import Foundation

// MARK: - Messages

/// Union message type — user, assistant, or tool result
public enum Message: Codable, Sendable, Identifiable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var id: String {
        switch self {
        case .user(let m): return m.id
        case .assistant(let m): return m.id
        case .toolResult(let m): return m.id
        }
    }

    public var role: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolResult: return "toolResult"
        }
    }

    public var timestamp: Date {
        switch self {
        case .user(let m): return m.timestamp
        case .assistant(let m): return m.timestamp
        case .toolResult(let m): return m.timestamp
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "user":
            self = .user(try UserMessage(from: decoder))
        case "assistant":
            self = .assistant(try AssistantMessage(from: decoder))
        case "toolResult":
            self = .toolResult(try ToolResultMessage(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .role, in: container, debugDescription: "Unknown role: \(role)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .user(let m): try m.encode(to: encoder)
        case .assistant(let m): try m.encode(to: encoder)
        case .toolResult(let m): try m.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case role }
}

// MARK: - User Message

public struct UserMessage: Codable, Sendable, Identifiable {
    public let id: String
    public var role: String = "user"
    public var content: UserContent
    public var timestamp: Date

    public init(id: String = UUID().uuidString, content: UserContent, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
    }

    public init(id: String = UUID().uuidString, text: String, timestamp: Date = Date()) {
        self.id = id
        self.content = .text(text)
        self.timestamp = timestamp
    }

    /// Convenience: get the text content regardless of form
    public var textContent: String {
        switch content {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Assistant Message

public struct AssistantMessage: Codable, Sendable, Identifiable {
    public let id: String
    public var role: String = "assistant"
    public var content: [AssistantContentBlock]
    public var api: Api?
    public var provider: Provider?
    public var model: String?
    public var usage: Usage?
    public var stopReason: StopReason?
    public var errorMessage: String?
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        content: [AssistantContentBlock] = [],
        api: Api? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        usage: Usage? = nil,
        stopReason: StopReason? = nil,
        errorMessage: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    /// Get all text content blocks joined
    public var textContent: String {
        content.compactMap { block in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined()
    }

    /// Get all thinking content blocks joined
    public var thinkingContent: String {
        content.compactMap { block in
            if case .thinking(let t) = block { return t.thinking }
            return nil
        }.joined()
    }

    /// Get all tool calls
    public var toolCalls: [ToolCall] {
        content.compactMap { block in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
    }

    /// Whether this message has any tool calls
    public var hasToolCalls: Bool {
        content.contains { block in
            if case .toolCall = block { return true }
            return false
        }
    }
}

// MARK: - Tool Result Message

public struct ToolResultMessage: Codable, Sendable, Identifiable {
    public let id: String
    public var role: String = "toolResult"
    public var toolCallId: String
    public var toolName: String
    public var content: [ToolResultContentBlock]
    public var isError: Bool
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        toolCallId: String,
        toolName: String,
        content: [ToolResultContentBlock],
        isError: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.timestamp = timestamp
    }

    /// Get the text content
    public var textContent: String {
        content.compactMap { block in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined(separator: "\n")
    }
}

// MARK: - Context

/// Full context for an LLM call
public struct Context: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]?

    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [ToolDefinition]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}
