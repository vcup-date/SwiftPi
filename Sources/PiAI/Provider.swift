import Foundation

// MARK: - Provider Protocol

/// Protocol for LLM API providers
public protocol LLMProvider: Sendable {
    /// The API type this provider handles
    var api: Api { get }

    /// Stream a completion with full options
    func stream(model: LLMModel, context: Context, options: StreamOptions) -> AssistantMessageEventStream

    /// Stream with simple options (reasoning support)
    func streamSimple(model: LLMModel, context: Context, options: SimpleStreamOptions) -> AssistantMessageEventStream
}

/// Default streamSimple implementation that delegates to stream
extension LLMProvider {
    public func streamSimple(model: LLMModel, context: Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        // Default: just pass through to stream, ignoring reasoning
        return stream(model: model, context: context, options: options.base)
    }
}

// MARK: - Provider Registry

/// Registry of LLM providers
public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    private var providers: [String: LLMProvider] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register a provider for an API type
    public func register(_ provider: LLMProvider) {
        lock.lock()
        providers[provider.api.description] = provider
        lock.unlock()
    }

    /// Get provider for an API type
    public func provider(for api: Api) -> LLMProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[api.description]
    }

    /// All registered provider API types
    public var registeredApis: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(providers.keys)
    }
}

// MARK: - Top-Level Streaming API

/// Stream a completion from any registered provider
public func stream(model: LLMModel, context: Context, options: StreamOptions = StreamOptions()) -> AssistantMessageEventStream {
    guard let provider = ProviderRegistry.shared.provider(for: model.api) else {
        let stream = AssistantMessageEventStream()
        stream.push(.error(reason: .error, error: StreamError.noProvider(api: model.api.description)))
        return stream
    }
    return provider.stream(model: model, context: context, options: options)
}

/// Stream with simple options (reasoning support)
public func streamSimple(model: LLMModel, context: Context, options: SimpleStreamOptions = SimpleStreamOptions()) -> AssistantMessageEventStream {
    guard let provider = ProviderRegistry.shared.provider(for: model.api) else {
        let stream = AssistantMessageEventStream()
        stream.push(.error(reason: .error, error: StreamError.noProvider(api: model.api.description)))
        return stream
    }
    return provider.streamSimple(model: model, context: context, options: options)
}

/// Complete (non-streaming) from any registered provider
public func complete(model: LLMModel, context: Context, options: StreamOptions = StreamOptions()) async throws -> AssistantMessage {
    try await stream(model: model, context: context, options: options).result()
}

/// Complete with simple options
public func completeSimple(model: LLMModel, context: Context, options: SimpleStreamOptions = SimpleStreamOptions()) async throws -> AssistantMessage {
    try await streamSimple(model: model, context: context, options: options).result()
}
