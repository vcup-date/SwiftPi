import Foundation
import PiAI
import PiAgent

// MARK: - Session Entry Types

/// A single entry in the session tree
public struct SessionEntry: Codable, Sendable, Identifiable {
    public let id: String
    public var parentId: String?
    public var entry: SessionEntryType
    public var timestamp: Date

    public init(id: String = UUID().uuidString, parentId: String? = nil, entry: SessionEntryType, timestamp: Date = Date()) {
        self.id = id
        self.parentId = parentId
        self.entry = entry
        self.timestamp = timestamp
    }
}

/// Types of entries that can be stored in a session
public enum SessionEntryType: Codable, Sendable {
    case header(SessionHeader)
    case message(Message)
    case thinkingLevelChange(ThinkingLevel)
    case modelChange(provider: String, modelId: String)
    case compaction(CompactionData)
    case branchSummary(String)
    case label(String?)
    case sessionInfo(name: String)
    case custom(type: String, data: [String: AnyCodable])

    private enum CodingKeys: String, CodingKey {
        case entryType, header, message, thinkingLevel, provider, modelId
        case compaction, summary, label, name, customType, customData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .entryType)

        switch type {
        case "header":
            self = .header(try container.decode(SessionHeader.self, forKey: .header))
        case "message":
            self = .message(try container.decode(Message.self, forKey: .message))
        case "thinkingLevelChange":
            self = .thinkingLevelChange(try container.decode(ThinkingLevel.self, forKey: .thinkingLevel))
        case "modelChange":
            self = .modelChange(
                provider: try container.decode(String.self, forKey: .provider),
                modelId: try container.decode(String.self, forKey: .modelId)
            )
        case "compaction":
            self = .compaction(try container.decode(CompactionData.self, forKey: .compaction))
        case "branchSummary":
            self = .branchSummary(try container.decode(String.self, forKey: .summary))
        case "label":
            self = .label(try container.decodeIfPresent(String.self, forKey: .label))
        case "sessionInfo":
            self = .sessionInfo(name: try container.decode(String.self, forKey: .name))
        case "custom":
            self = .custom(
                type: try container.decode(String.self, forKey: .customType),
                data: try container.decodeIfPresent([String: AnyCodable].self, forKey: .customData) ?? [:]
            )
        default:
            self = .custom(type: type, data: [:])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .header(let h):
            try container.encode("header", forKey: .entryType)
            try container.encode(h, forKey: .header)
        case .message(let m):
            try container.encode("message", forKey: .entryType)
            try container.encode(m, forKey: .message)
        case .thinkingLevelChange(let l):
            try container.encode("thinkingLevelChange", forKey: .entryType)
            try container.encode(l, forKey: .thinkingLevel)
        case .modelChange(let p, let m):
            try container.encode("modelChange", forKey: .entryType)
            try container.encode(p, forKey: .provider)
            try container.encode(m, forKey: .modelId)
        case .compaction(let c):
            try container.encode("compaction", forKey: .entryType)
            try container.encode(c, forKey: .compaction)
        case .branchSummary(let s):
            try container.encode("branchSummary", forKey: .entryType)
            try container.encode(s, forKey: .summary)
        case .label(let l):
            try container.encode("label", forKey: .entryType)
            try container.encodeIfPresent(l, forKey: .label)
        case .sessionInfo(let n):
            try container.encode("sessionInfo", forKey: .entryType)
            try container.encode(n, forKey: .name)
        case .custom(let t, let d):
            try container.encode("custom", forKey: .entryType)
            try container.encode(t, forKey: .customType)
            try container.encode(d, forKey: .customData)
        }
    }
}

/// Session header — first entry in every session
public struct SessionHeader: Codable, Sendable {
    public var version: Int = 3
    public var sessionId: String
    public var cwd: String
    public var parentSession: String?
    public var timestamp: Date

    public init(sessionId: String = UUID().uuidString, cwd: String, parentSession: String? = nil, timestamp: Date = Date()) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.parentSession = parentSession
        self.timestamp = timestamp
    }
}

/// Compaction data
public struct CompactionData: Codable, Sendable {
    public var summary: String
    public var firstKeptEntryId: String
    public var tokensBefore: Int

    public init(summary: String, firstKeptEntryId: String, tokensBefore: Int) {
        self.summary = summary
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
    }
}

/// Built session context
public struct SessionContext: Sendable {
    public var messages: [AgentMessage]
    public var thinkingLevel: ThinkingLevel
    public var model: (provider: String, modelId: String)?

    public init(messages: [AgentMessage] = [], thinkingLevel: ThinkingLevel = .off, model: (provider: String, modelId: String)? = nil) {
        self.messages = messages
        self.thinkingLevel = thinkingLevel
        self.model = model
    }
}
