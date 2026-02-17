import Foundation

// MARK: - API & Provider Types

/// Known LLM API protocols
public enum KnownApi: String, Codable, Sendable {
    case anthropicMessages = "anthropic-messages"
    case openaiCompletions = "openai-completions"
    case openaiResponses = "openai-responses"
    case googleGenerativeAI = "google-generative-ai"
    case bedrockConverseStream = "bedrock-converse-stream"
    case azureOpenaiResponses = "azure-openai-responses"
}

/// API type — either a known API or a custom string
public enum Api: Codable, Sendable, Hashable, CustomStringConvertible {
    case known(KnownApi)
    case custom(String)

    public var description: String {
        switch self {
        case .known(let api): return api.rawValue
        case .custom(let s): return s
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        if let known = KnownApi(rawValue: s) {
            self = .known(known)
        } else {
            self = .custom(s)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Known LLM providers
public enum KnownProvider: String, Codable, Sendable {
    case anthropic, openai, google, azure = "azure-openai"
    case bedrock = "amazon-bedrock", mistral, groq, cerebras
    case xai, openrouter, vercel, github = "github-copilot"
}

/// Provider type — known or custom
public enum Provider: Codable, Sendable, Hashable, CustomStringConvertible {
    case known(KnownProvider)
    case custom(String)

    public var description: String {
        switch self {
        case .known(let p): return p.rawValue
        case .custom(let s): return s
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        if let known = KnownProvider(rawValue: s) {
            self = .known(known)
        } else {
            self = .custom(s)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Thinking Level

/// Reasoning/thinking intensity level
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh
}

// MARK: - Stop Reason

/// Why the model stopped generating
public enum StopReason: String, Codable, Sendable {
    case stop, length, toolUse, error, aborted
}

// MARK: - Cache & Transport

/// Cache retention policy
public enum CacheRetention: String, Codable, Sendable {
    case none, short, long
}

/// HTTP transport mode
public enum Transport: String, Codable, Sendable {
    case sse, websocket, auto
}

// MARK: - Content Types

/// Text content block
public struct TextContent: Codable, Sendable, Equatable {
    public var type: String = "text"
    public var text: String
    public var textSignature: String?

    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

/// Thinking/reasoning content block
public struct ThinkingContent: Codable, Sendable, Equatable {
    public var type: String = "thinking"
    public var thinking: String
    public var thinkingSignature: String?

    public init(thinking: String, thinkingSignature: String? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
    }
}

/// Image content block (base64-encoded)
public struct ImageContent: Codable, Sendable, Equatable {
    public var type: String = "image"
    public var data: String // base64
    public var mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Tool call from assistant
public struct ToolCall: Codable, Sendable, Equatable {
    public var type: String = "toolCall"
    public var id: String
    public var name: String
    public var arguments: [String: AnyCodable]
    public var thoughtSignature: String?

    public init(id: String, name: String, arguments: [String: AnyCodable], thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

/// Assistant message content block — can be text, thinking, image, or tool call
public enum AssistantContentBlock: Codable, Sendable, Equatable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case toolCall(ToolCall)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try TextContent(from: decoder))
        case "thinking":
            self = .thinking(try ThinkingContent(from: decoder))
        case "toolCall":
            self = .toolCall(try ToolCall(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let c): try c.encode(to: encoder)
        case .thinking(let c): try c.encode(to: encoder)
        case .toolCall(let c): try c.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

/// User message content — either a string or array of content blocks
public enum UserContent: Codable, Sendable, Equatable {
    case text(String)
    case blocks([UserContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else {
            self = .blocks(try container.decode([UserContentBlock].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }
}

/// User content block — text or image
public enum UserContentBlock: Codable, Sendable, Equatable {
    case text(TextContent)
    case image(ImageContent)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try TextContent(from: decoder))
        case "image": self = .image(try ImageContent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown user content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let c): try c.encode(to: encoder)
        case .image(let c): try c.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case type }
}

/// Tool result content block — text or image
public enum ToolResultContentBlock: Codable, Sendable, Equatable {
    case text(TextContent)
    case image(ImageContent)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try TextContent(from: decoder))
        case "image": self = .image(try ImageContent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown result content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let c): try c.encode(to: encoder)
        case .image(let c): try c.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case type }
}

// MARK: - Token Usage

/// Token usage and cost tracking
public struct Usage: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var totalTokens: Int
    public var cost: UsageCost

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, totalTokens: Int = 0, cost: UsageCost = UsageCost()) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// Cost breakdown
public struct UsageCost: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }
}

// MARK: - Thinking Budgets

/// Token budget limits per thinking level
public struct ThinkingBudgets: Codable, Sendable {
    public var minimal: Int?
    public var low: Int?
    public var medium: Int?
    public var high: Int?

    public init(minimal: Int? = nil, low: Int? = nil, medium: Int? = nil, high: Int? = nil) {
        self.minimal = minimal
        self.low = low
        self.medium = medium
        self.high = high
    }

    public func budget(for level: ThinkingLevel) -> Int? {
        switch level {
        case .off: return nil
        case .minimal: return minimal
        case .low: return low
        case .medium: return medium
        case .high: return high
        case .xhigh: return nil // no limit
        }
    }
}

// MARK: - Stream Options

/// Base options for streaming
public struct StreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var apiKey: String?
    public var transport: Transport?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var maxRetryDelayMs: Int?
    public var headers: [String: String]?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        apiKey: String? = nil,
        transport: Transport? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        maxRetryDelayMs: Int? = nil,
        headers: [String: String]? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.apiKey = apiKey
        self.transport = transport
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.maxRetryDelayMs = maxRetryDelayMs
        self.headers = headers
    }
}

/// Options with reasoning/thinking support
public struct SimpleStreamOptions: Sendable {
    public var base: StreamOptions
    public var reasoning: ThinkingLevel?
    public var thinkingBudgets: ThinkingBudgets?

    public init(
        base: StreamOptions = StreamOptions(),
        reasoning: ThinkingLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil
    ) {
        self.base = base
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
    }
}

// MARK: - AnyCodable (for tool arguments)

/// Type-erased Codable value for JSON interop
public struct AnyCodable: Codable, Sendable, Equatable, CustomStringConvertible {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public var description: String {
        "\(value)"
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Compare via JSON encoding
        let encoder = JSONEncoder()
        guard let l = try? encoder.encode(lhs), let r = try? encoder.encode(rhs) else { return false }
        return l == r
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode("\(value)")
        }
    }

    // Convenience accessors
    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var doubleValue: Double? { value as? Double }
    public var boolValue: Bool? { value as? Bool }
    public var arrayValue: [Any]? { value as? [Any] }
    public var dictValue: [String: Any]? { value as? [String: Any] }
}
