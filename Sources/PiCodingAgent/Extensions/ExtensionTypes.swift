import Foundation
import PiAI
import PiAgent

// MARK: - Extension System Types

/// A loaded extension
public struct Extension: Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var tools: [AgentTool]
    public var commands: [ExtensionCommand]

    public init(path: String, name: String, tools: [AgentTool] = [], commands: [ExtensionCommand] = []) {
        self.path = path
        self.name = name
        self.tools = tools
        self.commands = commands
    }
}

/// A command registered by an extension
public struct ExtensionCommand: Sendable {
    public var name: String
    public var description: String
    public var handler: @Sendable (String) async throws -> String?

    public init(name: String, description: String, handler: @escaping @Sendable (String) async throws -> String?) {
        self.name = name
        self.description = description
        self.handler = handler
    }
}

/// Extension loading result
public struct LoadExtensionsResult: Sendable {
    public var extensions: [Extension]
    public var errors: [(path: String, error: String)]

    public init(extensions: [Extension] = [], errors: [(path: String, error: String)] = []) {
        self.extensions = extensions
        self.errors = errors
    }
}

// MARK: - Extension Event Types

/// Events that extensions can listen to
public enum ExtensionEvent: Sendable {
    case sessionStart
    case sessionShutdown
    case agentStart
    case agentEnd(messages: [AgentMessage])
    case turnStart
    case turnEnd(message: AssistantMessage, toolResults: [ToolResultMessage])
    case messageStart(message: AssistantMessage)
    case messageEnd(message: AssistantMessage)
    case toolCall(toolName: String, args: [String: AnyCodable])
    case toolResult(toolName: String, result: AgentToolResult)
    case input(text: String)
}
