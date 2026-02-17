import Foundation
import PiAI
import PiAgent

// MARK: - Session Manager

/// Manages conversation sessions as append-only trees stored in JSONL files
public final class SessionManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var entries: [SessionEntry] = []
    @Published public private(set) var leafId: String?

    public let filePath: String?
    public let sessionId: String
    public let cwd: String

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Factory Methods

    /// Create a new file-backed session
    public static func create(cwd: String) throws -> SessionManager {
        let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".swiftpi/sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

        let sessionId = UUID().uuidString
        let filePath = (sessionsDir as NSString).appendingPathComponent("\(sessionId).jsonl")

        let manager = SessionManager(filePath: filePath, sessionId: sessionId, cwd: cwd)

        // Write header
        let header = SessionHeader(sessionId: sessionId, cwd: cwd)
        let headerEntry = SessionEntry(entry: .header(header))
        manager.appendEntry(headerEntry)

        return manager
    }

    /// Create an in-memory session (no persistence)
    public static func inMemory(cwd: String) -> SessionManager {
        SessionManager(filePath: nil, sessionId: UUID().uuidString, cwd: cwd)
    }

    /// Open an existing session from file
    public static func open(path: String) throws -> SessionManager {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SessionError.fileNotFound(path)
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        let decoder = JSONDecoder()
        var entries: [SessionEntry] = []

        for line in lines {
            if let data = line.data(using: .utf8),
               let entry = try? decoder.decode(SessionEntry.self, from: data) {
                entries.append(entry)
            }
        }

        guard let firstEntry = entries.first,
              case .header(let header) = firstEntry.entry else {
            throw SessionError.invalidSession("No header found")
        }

        let manager = SessionManager(filePath: path, sessionId: header.sessionId, cwd: header.cwd)
        manager.entries = entries

        // Set leaf to last entry
        if let last = entries.last {
            manager.leafId = last.id
        }

        return manager
    }

    /// List all sessions
    public static func listAll() -> [(path: String, sessionId: String, cwd: String, timestamp: Date)] {
        let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".swiftpi/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        var sessions: [(path: String, sessionId: String, cwd: String, timestamp: Date)] = []

        for file in files where file.hasSuffix(".jsonl") {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let firstLine = content.components(separatedBy: "\n").first,
               let data = firstLine.data(using: .utf8),
               let entry = try? JSONDecoder().decode(SessionEntry.self, from: data),
               case .header(let header) = entry.entry {
                sessions.append((path: path, sessionId: header.sessionId, cwd: header.cwd, timestamp: header.timestamp))
            }
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Init

    private init(filePath: String?, sessionId: String, cwd: String) {
        self.filePath = filePath
        self.sessionId = sessionId
        self.cwd = cwd
    }

    // MARK: - Append Methods

    /// Append a message to the session
    public func appendMessage(_ message: Message) {
        let entry = SessionEntry(
            parentId: leafId,
            entry: .message(message)
        )
        appendEntry(entry)
    }

    /// Append a thinking level change
    public func appendThinkingLevelChange(_ level: ThinkingLevel) {
        let entry = SessionEntry(
            parentId: leafId,
            entry: .thinkingLevelChange(level)
        )
        appendEntry(entry)
    }

    /// Append a model change
    public func appendModelChange(provider: String, modelId: String) {
        let entry = SessionEntry(
            parentId: leafId,
            entry: .modelChange(provider: provider, modelId: modelId)
        )
        appendEntry(entry)
    }

    /// Append a compaction entry
    public func appendCompaction(_ data: CompactionData) {
        let entry = SessionEntry(
            parentId: leafId,
            entry: .compaction(data)
        )
        appendEntry(entry)
    }

    /// Append a label
    public func appendLabel(_ label: String?) {
        let entry = SessionEntry(
            parentId: leafId,
            entry: .label(label)
        )
        appendEntry(entry)
    }

    /// Append session name
    public func appendSessionInfo(name: String) {
        let entry = SessionEntry(
            parentId: leafId,
            entry: .sessionInfo(name: name)
        )
        appendEntry(entry)
    }

    /// Core append method
    private func appendEntry(_ entry: SessionEntry) {
        lock.lock()
        entries.append(entry)
        leafId = entry.id
        lock.unlock()

        // Persist to file
        if let filePath {
            if let data = try? encoder.encode(entry),
               let line = String(data: data, encoding: .utf8) {
                let lineWithNewline = line + "\n"
                if let handle = FileHandle(forWritingAtPath: filePath) {
                    handle.seekToEndOfFile()
                    handle.write(lineWithNewline.data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    try? lineWithNewline.write(toFile: filePath, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - Tree Navigation

    /// Get the path from root to the given entry
    public func getBranch(to entryId: String) -> [SessionEntry] {
        lock.lock()
        defer { lock.unlock() }

        var path: [SessionEntry] = []
        var currentId: String? = entryId

        while let id = currentId {
            guard let entry = entries.first(where: { $0.id == id }) else { break }
            path.insert(entry, at: 0)
            currentId = entry.parentId
        }

        return path
    }

    /// Get children of an entry
    public func getChildren(of parentId: String) -> [SessionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.parentId == parentId }
    }

    /// Move leaf to a different entry (branching)
    public func branch(to entryId: String) {
        lock.lock()
        leafId = entryId
        lock.unlock()
    }

    /// Get the session name
    public var sessionName: String? {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries.reversed() {
            if case .sessionInfo(let name) = entry.entry {
                return name
            }
        }
        return nil
    }

    // MARK: - Build Context

    /// Build the current session context by walking from leaf to root
    public func buildContext() -> SessionContext {
        lock.lock()
        let currentEntries = entries
        let currentLeaf = leafId
        lock.unlock()

        guard let leafId = currentLeaf else {
            return SessionContext()
        }

        // Walk from leaf to root
        let path = getBranch(to: leafId)

        var messages: [AgentMessage] = []
        var thinkingLevel: ThinkingLevel = .off
        var model: (provider: String, modelId: String)?
        var compactionSummary: String?

        for entry in path {
            switch entry.entry {
            case .header:
                break
            case .message(let msg):
                messages.append(.message(msg))
            case .thinkingLevelChange(let level):
                thinkingLevel = level
            case .modelChange(let p, let m):
                model = (p, m)
            case .compaction(let data):
                compactionSummary = data.summary
                // Clear messages before compaction point
                messages.removeAll()
                // Add summary as user message
                messages.append(.user("Previous conversation summary:\n\(data.summary)"))
            case .branchSummary(let summary):
                messages.append(.user("Branch summary:\n\(summary)"))
            case .label, .sessionInfo, .custom:
                break
            }
        }

        return SessionContext(messages: messages, thinkingLevel: thinkingLevel, model: model)
    }

    // MARK: - Info

    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var messageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { if case .message = $0.entry { return true }; return false }.count
    }
}

// MARK: - Errors

public enum SessionError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidSession(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "Session file not found: \(p)"
        case .invalidSession(let m): return "Invalid session: \(m)"
        }
    }
}
