import Foundation
import PiAI
import PiAgent

// MARK: - Extension Runner

/// Manages loaded extensions and dispatches events to them
public final class ExtensionRunner: ObservableObject, @unchecked Sendable {
    @Published public private(set) var extensions: [Extension]
    private var eventHandlers: [String: [(ExtensionEvent) async -> Void]] = [:]
    private let lock = NSLock()

    public init(extensions: [Extension] = []) {
        self.extensions = extensions
    }

    /// Add extensions
    public func addExtensions(_ newExtensions: [Extension]) {
        lock.lock()
        extensions.append(contentsOf: newExtensions)
        lock.unlock()
    }

    /// Get all tools from extensions
    public var allTools: [AgentTool] {
        lock.lock()
        defer { lock.unlock() }
        return extensions.flatMap { $0.tools }
    }

    /// Get all commands from extensions
    public var allCommands: [ExtensionCommand] {
        lock.lock()
        defer { lock.unlock() }
        return extensions.flatMap { $0.commands }
    }

    /// Register an event handler
    public func on(_ eventType: String, handler: @escaping (ExtensionEvent) async -> Void) {
        lock.lock()
        eventHandlers[eventType, default: []].append(handler)
        lock.unlock()
    }

    /// Emit an event to all registered handlers
    public func emit(_ event: ExtensionEvent) async {
        let eventType: String
        switch event {
        case .sessionStart: eventType = "sessionStart"
        case .sessionShutdown: eventType = "sessionShutdown"
        case .agentStart: eventType = "agentStart"
        case .agentEnd: eventType = "agentEnd"
        case .turnStart: eventType = "turnStart"
        case .turnEnd: eventType = "turnEnd"
        case .messageStart: eventType = "messageStart"
        case .messageEnd: eventType = "messageEnd"
        case .toolCall: eventType = "toolCall"
        case .toolResult: eventType = "toolResult"
        case .input: eventType = "input"
        }

        lock.lock()
        let handlers = eventHandlers[eventType] ?? []
        lock.unlock()

        for handler in handlers {
            await handler(event)
        }
    }

    /// Execute a command by name
    public func executeCommand(_ name: String, args: String = "") async throws -> String? {
        lock.lock()
        let commands = extensions.flatMap { $0.commands }.filter { $0.name == name }
        lock.unlock()

        guard let command = commands.first else {
            return nil
        }

        return try await command.handler(args)
    }
}
