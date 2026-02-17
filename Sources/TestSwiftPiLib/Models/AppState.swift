import Foundation
import SwiftUI
import PiAI
import PiAgent
import PiCodingAgent

// MARK: - App State

/// Global app state managing the agent session and UI state
@MainActor
public final class AppState: ObservableObject {
    @Published public var agentSession: AgentSession
    @Published public var selectedTab: AppTab = .chat
    @Published public var showConfig = false
    @Published public var showPromptEditor = false

    public let apiKeyManager: APIKeyManager
    public let settingsManager: SettingsManager

    public init() {
        // Use a safe default working directory instead of potentially landing on /
        let rawCwd = FileManager.default.currentDirectoryPath
        let cwd: String
        if rawCwd == "/" {
            let workspace = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftpi/workspace").path
            try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
            cwd = workspace
        } else {
            cwd = rawCwd
        }
        let keyManager = APIKeyManager()
        let settingsMgr = SettingsManager(cwd: cwd)

        self.apiKeyManager = keyManager
        self.settingsManager = settingsMgr

        // Determine initial model — restore full saved model, or fallback to builtin, or nil
        let model: LLMModel?
        if let saved = settingsMgr.lastModel {
            model = saved
        } else if let defaultModel = settingsMgr.defaultModel,
                  let found = BuiltinModels.find(defaultModel) {
            model = found
        } else {
            model = nil // Let AgentSession use a neutral default
        }

        self.agentSession = AgentSession(
            cwd: cwd,
            model: model,
            apiKeyManager: keyManager,
            settingsManager: settingsMgr
        )

        // Initialize PiAI providers
        initializePiAI()
    }

    /// Create a new session
    public func newSession() {
        let cwd = agentSession.cwd
        agentSession = AgentSession(
            cwd: cwd,
            model: agentSession.model,
            apiKeyManager: apiKeyManager,
            settingsManager: settingsManager
        )
    }
}

/// App tabs
public enum AppTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case events = "Events"
    case config = "Config"
    case prompts = "Prompts"
    case skills = "Skills"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .events: return "list.bullet.rectangle"
        case .config: return "gear"
        case .prompts: return "doc.text"
        case .skills: return "star"
        }
    }
}
