import Foundation

// MARK: - PiAI Module Entry Point

/// Initialize the PiAI module — registers built-in providers
public func initializePiAI() {
    ProviderRegistry.shared.register(AnthropicProvider())
    ProviderRegistry.shared.register(OpenAIProvider(api: .known(.openaiResponses)))
    ProviderRegistry.shared.register(OpenAIProvider(api: .known(.openaiCompletions)))
}
