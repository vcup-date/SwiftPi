import Foundation

// MARK: - API Key Manager

/// Manages API keys for multiple providers, with persistence
public final class APIKeyManager: ObservableObject, @unchecked Sendable {
    public struct ProviderKey: Codable, Sendable, Identifiable, Equatable {
        public var id: String { "\(provider)-\(name)" }
        public var provider: String
        public var name: String
        public var apiKey: String
        public var baseUrl: String?
        public var isSelected: Bool

        public init(provider: String, name: String, apiKey: String, baseUrl: String? = nil, isSelected: Bool = false) {
            self.provider = provider
            self.name = name
            self.apiKey = apiKey
            self.baseUrl = baseUrl
            self.isSelected = isSelected
        }
    }

    @Published public var keys: [ProviderKey] = []
    private let storageUrl: URL?
    private let lock = NSLock()

    public init(storageUrl: URL? = nil) {
        if let storageUrl {
            self.storageUrl = storageUrl
        } else {
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".swiftpi")
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            self.storageUrl = configDir.appendingPathComponent("api-keys.json")
        }
        load()
    }

    /// In-memory only (no persistence)
    public init(keys: [ProviderKey]) {
        self.storageUrl = nil
        self.keys = keys
    }

    // MARK: - CRUD

    /// Add or update a key
    public func setKey(_ key: ProviderKey) {
        lock.lock()
        defer { lock.unlock() }

        if let idx = keys.firstIndex(where: { $0.provider == key.provider && $0.name == key.name }) {
            keys[idx] = key
        } else {
            keys.append(key)
        }

        // Global selection: only one key active at a time
        if key.isSelected {
            for i in keys.indices where !(keys[i].provider == key.provider && keys[i].name == key.name) {
                keys[i].isSelected = false
            }
        } else if !keys.contains(where: { $0.isSelected }) {
            // If nothing selected at all, select this key
            if let idx = keys.firstIndex(where: { $0.provider == key.provider && $0.name == key.name }) {
                keys[idx].isSelected = true
            }
        }

        save()
    }

    /// Remove a key
    public func removeKey(provider: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        keys.removeAll { $0.provider == provider && $0.name == name }
        save()
    }

    /// Select a key (global — deselects all others)
    public func selectKey(provider: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        for i in keys.indices {
            keys[i].isSelected = (keys[i].provider == provider && keys[i].name == name)
        }
        save()
    }

    /// Get the currently selected API key for a provider
    public func apiKey(for provider: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys.first { $0.provider == provider && $0.isSelected }?.apiKey
    }

    /// Get the currently selected API key for a Provider enum
    public func apiKey(for provider: Provider) -> String? {
        return apiKey(for: provider.description)
    }

    /// Get base URL override for a provider
    public func baseUrl(for provider: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys.first { $0.provider == provider && $0.isSelected }?.baseUrl
    }

    /// Get all keys for a provider
    public func keys(for provider: String) -> [ProviderKey] {
        lock.lock()
        defer { lock.unlock() }
        return keys.filter { $0.provider == provider }
    }

    /// Resolve API key for a model — checks model provider, any selected key, then env vars
    public func resolveApiKey(for model: LLMModel) -> String? {
        // 1. Check stored keys matching model provider
        if let key = apiKey(for: model.provider) {
            return key
        }

        // 2. Check ANY selected key (for custom providers like OpenRouter, Together, etc.)
        lock.lock()
        let anySelected = keys.first(where: { $0.isSelected })
        lock.unlock()
        if let anySelected {
            return anySelected.apiKey
        }

        // 3. Check environment variables
        let envKey: String?
        switch model.provider {
        case .known(.anthropic): envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        case .known(.openai): envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        case .known(.google): envKey = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
        case .known(.azure): envKey = ProcessInfo.processInfo.environment["AZURE_OPENAI_API_KEY"]
        default: envKey = nil
        }

        return envKey
    }

    /// Resolve base URL for a model — checks model's baseUrl, then selected key's baseUrl
    public func resolveBaseUrl(for model: LLMModel) -> String? {
        if let url = model.baseUrl, !url.isEmpty {
            return url
        }
        lock.lock()
        let selected = keys.first(where: { $0.isSelected })
        lock.unlock()
        return selected?.baseUrl
    }

    // MARK: - Persistence

    private func load() {
        guard let storageUrl, FileManager.default.fileExists(atPath: storageUrl.path) else { return }
        do {
            let data = try Data(contentsOf: storageUrl)
            keys = try JSONDecoder().decode([ProviderKey].self, from: data)
        } catch {
            // Ignore load errors — start fresh
        }
    }

    private func save() {
        guard let storageUrl else { return }
        do {
            let data = try JSONEncoder().encode(keys)
            try data.write(to: storageUrl, options: .atomic)
        } catch {
            // Ignore save errors
        }
    }
}
