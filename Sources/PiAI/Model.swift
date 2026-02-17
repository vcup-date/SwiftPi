import Foundation

// MARK: - Model Definition

/// LLM model configuration
public struct LLMModel: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var api: Api
    public var provider: Provider
    public var baseUrl: String?
    public var reasoning: Bool
    public var inputModalities: [String] // "text", "image"
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int
    public var headers: [String: String]?

    public init(
        id: String,
        name: String,
        api: Api,
        provider: Provider,
        baseUrl: String? = nil,
        reasoning: Bool = false,
        inputModalities: [String] = ["text"],
        cost: ModelCost = ModelCost(),
        contextWindow: Int = 128_000,
        maxTokens: Int = 4096,
        headers: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseUrl = baseUrl
        self.reasoning = reasoning
        self.inputModalities = inputModalities
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.headers = headers
    }

    /// Whether this model supports image input
    public var supportsImages: Bool {
        inputModalities.contains("image")
    }
}

/// Per-token cost in USD per million tokens
public struct ModelCost: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

// MARK: - Built-in Models

public enum BuiltinModels {
    // Anthropic
    public static let claude4Opus = LLMModel(
        id: "claude-opus-4-6",
        name: "Claude Opus 4.6",
        api: .known(.anthropicMessages),
        provider: .known(.anthropic),
        reasoning: true,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        contextWindow: 200_000,
        maxTokens: 32_000
    )

    public static let claude4Sonnet = LLMModel(
        id: "claude-sonnet-4-5-20250929",
        name: "Claude Sonnet 4.5",
        api: .known(.anthropicMessages),
        provider: .known(.anthropic),
        reasoning: true,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        contextWindow: 200_000,
        maxTokens: 16_384
    )

    public static let claude4Haiku = LLMModel(
        id: "claude-haiku-4-5-20251001",
        name: "Claude Haiku 4.5",
        api: .known(.anthropicMessages),
        provider: .known(.anthropic),
        reasoning: false,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
        contextWindow: 200_000,
        maxTokens: 8_192
    )

    // OpenAI
    public static let gpt4o = LLMModel(
        id: "gpt-4o",
        name: "GPT-4o",
        api: .known(.openaiResponses),
        provider: .known(.openai),
        reasoning: false,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 2.5, output: 10),
        contextWindow: 128_000,
        maxTokens: 16_384
    )

    public static let gpt4oMini = LLMModel(
        id: "gpt-4o-mini",
        name: "GPT-4o Mini",
        api: .known(.openaiResponses),
        provider: .known(.openai),
        reasoning: false,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 0.15, output: 0.6),
        contextWindow: 128_000,
        maxTokens: 16_384
    )

    public static let o3 = LLMModel(
        id: "o3",
        name: "o3",
        api: .known(.openaiResponses),
        provider: .known(.openai),
        reasoning: true,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 10, output: 40),
        contextWindow: 200_000,
        maxTokens: 100_000
    )

    public static let o4Mini = LLMModel(
        id: "o4-mini",
        name: "o4-mini",
        api: .known(.openaiResponses),
        provider: .known(.openai),
        reasoning: true,
        inputModalities: ["text", "image"],
        cost: ModelCost(input: 1.1, output: 4.4),
        contextWindow: 200_000,
        maxTokens: 100_000
    )

    /// All built-in models
    public static let all: [LLMModel] = [
        claude4Opus, claude4Sonnet, claude4Haiku,
        gpt4o, gpt4oMini, o3, o4Mini
    ]

    /// Find model by ID (case-insensitive partial match)
    public static func find(_ query: String) -> LLMModel? {
        let q = query.lowercased()
        return all.first { $0.id.lowercased() == q }
            ?? all.first { $0.id.lowercased().contains(q) }
            ?? all.first { $0.name.lowercased().contains(q) }
    }
}
