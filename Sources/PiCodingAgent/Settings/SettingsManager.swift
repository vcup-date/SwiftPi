import Foundation
import PiAI

// MARK: - Settings

/// User settings with persistence
public struct Settings: Codable, Sendable {
    public var defaultProvider: String?
    public var defaultModel: String?
    public var defaultThinkingLevel: ThinkingLevel?
    public var lastModel: LLMModel?
    public var transport: Transport?
    public var theme: String?
    public var steeringMode: String? // "all" | "one-at-a-time"
    public var followUpMode: String? // "all" | "one-at-a-time"
    public var compaction: CompactionSettings?
    public var retry: RetrySettings?
    public var extensions: [String]?
    public var skills: [String]?
    public var prompts: [String]?
    public var enableSkillCommands: Bool?
    public var shellPath: String?
    public var quietStartup: Bool?
    public var hideThinkingBlock: Bool?

    public init() {}
}

/// Compaction settings
public struct CompactionSettings: Codable, Sendable {
    public var enabled: Bool?
    public var reserveTokens: Int?
    public var keepRecentTokens: Int?

    public init(enabled: Bool? = true, reserveTokens: Int? = 16384, keepRecentTokens: Int? = 20000) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
    }
}

/// Retry settings
public struct RetrySettings: Codable, Sendable {
    public var enabled: Bool?
    public var maxRetries: Int?
    public var baseDelayMs: Int?
    public var maxDelayMs: Int?

    public init(enabled: Bool? = true, maxRetries: Int? = 3, baseDelayMs: Int? = 2000, maxDelayMs: Int? = 60000) {
        self.enabled = enabled
        self.maxRetries = maxRetries
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
    }
}

// MARK: - Settings Manager

/// Manages global and project-local settings with persistence
public final class SettingsManager: ObservableObject, @unchecked Sendable {
    @Published public var globalSettings: Settings
    @Published public var projectSettings: Settings

    private let globalPath: String
    private let projectPath: String?
    private let lock = NSLock()

    /// Resolved settings (project overrides global)
    public var resolved: Settings {
        merge(global: globalSettings, project: projectSettings)
    }

    // MARK: - Init

    public init(cwd: String? = nil) {
        let globalDir = (NSHomeDirectory() as NSString).appendingPathComponent(".swiftpi")
        try? FileManager.default.createDirectory(atPath: globalDir, withIntermediateDirectories: true)
        self.globalPath = (globalDir as NSString).appendingPathComponent("settings.json")

        if let cwd {
            let projectDir = (cwd as NSString).appendingPathComponent(".swiftpi")
            self.projectPath = (projectDir as NSString).appendingPathComponent("settings.json")
        } else {
            self.projectPath = nil
        }

        self.globalSettings = Settings()
        self.projectSettings = Settings()

        load()
    }

    /// In-memory settings (no persistence)
    public init(settings: Settings) {
        self.globalPath = ""
        self.projectPath = nil
        self.globalSettings = settings
        self.projectSettings = Settings()
    }

    // MARK: - Access

    public var defaultProvider: String? { resolved.defaultProvider }
    public var defaultModel: String? { resolved.defaultModel }
    public var defaultThinkingLevel: ThinkingLevel { resolved.defaultThinkingLevel ?? .off }
    public var lastModel: LLMModel? { resolved.lastModel }

    public var compaction: CompactionSettings {
        resolved.compaction ?? CompactionSettings()
    }

    public var retry: RetrySettings {
        resolved.retry ?? RetrySettings()
    }

    public var isCompactionEnabled: Bool {
        compaction.enabled ?? true
    }

    public var isRetryEnabled: Bool {
        retry.enabled ?? true
    }

    public var skillPaths: [String] {
        resolved.skills ?? []
    }

    public var extensionPaths: [String] {
        resolved.extensions ?? []
    }

    public var promptPaths: [String] {
        resolved.prompts ?? []
    }

    // MARK: - Mutation

    public func setDefaultModel(_ model: String?) {
        lock.lock()
        globalSettings.defaultModel = model
        lock.unlock()
        save()
    }

    public func setDefaultProvider(_ provider: String?) {
        lock.lock()
        globalSettings.defaultProvider = provider
        lock.unlock()
        save()
    }

    public func setDefaultThinkingLevel(_ level: ThinkingLevel) {
        lock.lock()
        globalSettings.defaultThinkingLevel = level
        lock.unlock()
        save()
    }

    public func setCompactionEnabled(_ enabled: Bool) {
        lock.lock()
        if globalSettings.compaction == nil {
            globalSettings.compaction = CompactionSettings()
        }
        globalSettings.compaction?.enabled = enabled
        lock.unlock()
        save()
    }

    public func setRetryEnabled(_ enabled: Bool) {
        lock.lock()
        if globalSettings.retry == nil {
            globalSettings.retry = RetrySettings()
        }
        globalSettings.retry?.enabled = enabled
        lock.unlock()
        save()
    }

    public func setLastModel(_ model: LLMModel?) {
        lock.lock()
        globalSettings.lastModel = model
        lock.unlock()
        save()
    }

    // MARK: - Persistence

    public func load() {
        if !globalPath.isEmpty, FileManager.default.fileExists(atPath: globalPath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: globalPath)),
               let settings = try? JSONDecoder().decode(Settings.self, from: data) {
                globalSettings = settings
            }
        }

        if let projectPath, FileManager.default.fileExists(atPath: projectPath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: projectPath)),
               let settings = try? JSONDecoder().decode(Settings.self, from: data) {
                projectSettings = settings
            }
        }
    }

    public func save() {
        guard !globalPath.isEmpty else { return }
        if let data = try? JSONEncoder().encode(globalSettings) {
            try? data.write(to: URL(fileURLWithPath: globalPath), options: .atomic)
        }
    }

    public func reload() {
        load()
    }

    // MARK: - Merge

    private func merge(global: Settings, project: Settings) -> Settings {
        var result = global

        if let v = project.defaultProvider { result.defaultProvider = v }
        if let v = project.defaultModel { result.defaultModel = v }
        if let v = project.defaultThinkingLevel { result.defaultThinkingLevel = v }
        if let v = project.transport { result.transport = v }
        if let v = project.theme { result.theme = v }
        if let v = project.steeringMode { result.steeringMode = v }
        if let v = project.followUpMode { result.followUpMode = v }
        if let v = project.compaction { result.compaction = v }
        if let v = project.retry { result.retry = v }
        if let v = project.extensions { result.extensions = (result.extensions ?? []) + v }
        if let v = project.skills { result.skills = (result.skills ?? []) + v }
        if let v = project.prompts { result.prompts = (result.prompts ?? []) + v }
        if let v = project.enableSkillCommands { result.enableSkillCommands = v }
        if let v = project.shellPath { result.shellPath = v }
        if let v = project.quietStartup { result.quietStartup = v }
        if let v = project.lastModel { result.lastModel = v }

        return result
    }
}
