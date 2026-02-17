import Foundation
import PiAI
import PiAgent

// MARK: - Compaction Engine

/// Result of compaction
public struct CompactionResult: Sendable {
    public var summary: String
    public var firstKeptEntryId: String
    public var tokensBefore: Int
    public var tokensAfter: Int

    public init(summary: String, firstKeptEntryId: String, tokensBefore: Int, tokensAfter: Int) {
        self.summary = summary
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}

/// Context usage estimate
public struct ContextUsageEstimate: Sendable {
    public var tokens: Int
    public var usageTokens: Int
    public var trailingTokens: Int

    public init(tokens: Int = 0, usageTokens: Int = 0, trailingTokens: Int = 0) {
        self.tokens = tokens
        self.usageTokens = usageTokens
        self.trailingTokens = trailingTokens
    }
}

// MARK: - Token Estimation

/// Estimate the number of tokens in text (chars/4 heuristic)
public func estimateTokens(_ text: String) -> Int {
    max(1, text.count / 4)
}

/// Estimate tokens for a message
public func estimateMessageTokens(_ message: Message) -> Int {
    switch message {
    case .user(let m):
        return estimateTokens(m.textContent)
    case .assistant(let m):
        if let usage = m.usage {
            return usage.totalTokens > 0 ? usage.output : estimateTokens(m.textContent + m.thinkingContent)
        }
        return estimateTokens(m.textContent + m.thinkingContent)
    case .toolResult(let m):
        return estimateTokens(m.textContent)
    }
}

/// Estimate tokens for agent messages
public func estimateContextTokens(_ messages: [AgentMessage]) -> ContextUsageEstimate {
    var totalTokens = 0
    var usageTokens = 0
    var trailingTokens = 0
    var lastUsageIndex: Int?

    for (idx, msg) in messages.enumerated() {
        let tokens: Int
        if let message = msg.asMessage {
            tokens = estimateMessageTokens(message)
            // Track actual usage from assistant messages
            if case .assistant(let am) = message, let usage = am.usage {
                usageTokens = usage.input + usage.output
                lastUsageIndex = idx
                trailingTokens = 0
            } else {
                trailingTokens += tokens
            }
        } else {
            tokens = 50 // Default for custom messages
            trailingTokens += tokens
        }
        totalTokens += tokens
    }

    // If we have actual usage data, prefer it
    if lastUsageIndex != nil {
        totalTokens = usageTokens + trailingTokens
    }

    return ContextUsageEstimate(
        tokens: totalTokens,
        usageTokens: usageTokens,
        trailingTokens: trailingTokens
    )
}

// MARK: - Compaction Logic

/// Whether compaction is needed
public func shouldCompact(contextTokens: Int, contextWindow: Int, reserveTokens: Int = 16384) -> Bool {
    contextTokens > contextWindow - reserveTokens
}

/// Find the cut point for compaction
public func findCutPoint(
    messages: [AgentMessage],
    keepRecentTokens: Int = 20000
) -> Int {
    var tokenCount = 0

    // Walk backwards, accumulating tokens
    for i in stride(from: messages.count - 1, through: 0, by: -1) {
        let tokens: Int
        if let msg = messages[i].asMessage {
            tokens = estimateMessageTokens(msg)
        } else {
            tokens = 50
        }

        tokenCount += tokens

        if tokenCount >= keepRecentTokens {
            // Find a valid cut point (user or assistant message boundary)
            for j in i...min(i + 5, messages.count - 1) {
                if let msg = messages[j].asMessage {
                    switch msg {
                    case .user, .assistant:
                        return j
                    case .toolResult:
                        continue // Don't cut at tool result
                    }
                }
            }
            return i
        }
    }

    return 0 // Can't cut, keep everything
}

/// Perform compaction by summarizing old messages
public func compact(
    messages: [AgentMessage],
    model: LLMModel,
    contextWindow: Int,
    settings: CompactionSettings = CompactionSettings(),
    apiKeyManager: APIKeyManager? = nil,
    existingSummary: String? = nil
) async throws -> CompactionResult {
    let keepRecentTokens = settings.keepRecentTokens ?? 20000
    let cutPoint = findCutPoint(messages: messages, keepRecentTokens: keepRecentTokens)

    guard cutPoint > 0 else {
        throw CompactionError.cannotCompact("Not enough messages to compact")
    }

    let messagesToSummarize = Array(messages[0..<cutPoint])
    let tokensBefore = estimateContextTokens(messages).tokens

    // Build summarization prompt
    var summaryPrompt = """
    Summarize the following conversation into a structured checkpoint. Include:
    1. **Goal**: What the user is trying to accomplish
    2. **Progress**: What has been done so far
    3. **Current State**: Where things stand now
    4. **Key Decisions**: Important decisions made
    5. **Next Steps**: What should happen next
    6. **Files Modified**: List of files that were read or modified

    Keep it concise but complete. This summary will replace the conversation history.
    """

    if let existing = existingSummary {
        summaryPrompt += "\n\nPrevious summary to incorporate:\n\(existing)"
    }

    // Format messages for summarization
    var conversationText = ""
    for msg in messagesToSummarize {
        if let message = msg.asMessage {
            switch message {
            case .user(let m):
                conversationText += "User: \(m.textContent)\n\n"
            case .assistant(let m):
                conversationText += "Assistant: \(m.textContent)\n\n"
            case .toolResult(let m):
                let truncated = String(m.textContent.prefix(500))
                conversationText += "Tool (\(m.toolName)): \(truncated)\n\n"
            }
        }
    }

    // Use LLM to generate summary
    let context = Context(
        messages: [
            .user(UserMessage(text: summaryPrompt + "\n\n---\n\n" + conversationText))
        ]
    )

    let options = SimpleStreamOptions(
        base: StreamOptions(apiKey: apiKeyManager?.resolveApiKey(for: model))
    )

    let result = try await completeSimple(model: model, context: context, options: options)
    let summary = result.textContent

    // Find the first kept entry ID
    let firstKeptId = messages[cutPoint].id

    let keptMessages = Array(messages[cutPoint...])
    let tokensAfter = estimateContextTokens(keptMessages).tokens + estimateTokens(summary)

    return CompactionResult(
        summary: summary,
        firstKeptEntryId: firstKeptId,
        tokensBefore: tokensBefore,
        tokensAfter: tokensAfter
    )
}

// MARK: - Errors

public enum CompactionError: Error, LocalizedError {
    case cannotCompact(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCompact(let m): return "Cannot compact: \(m)"
        }
    }
}
