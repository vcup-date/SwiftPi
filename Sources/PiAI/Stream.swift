import Foundation

// MARK: - Assistant Message Events

/// Streaming event for assistant message generation
public enum AssistantMessageEvent: Sendable {
    /// Stream started
    case start(partial: AssistantMessage)
    /// Text block started
    case textStart(contentIndex: Int, partial: TextContent)
    /// Text delta
    case textDelta(contentIndex: Int, delta: String)
    /// Text block ended
    case textEnd(contentIndex: Int, content: TextContent)
    /// Thinking block started
    case thinkingStart(contentIndex: Int, partial: ThinkingContent)
    /// Thinking delta
    case thinkingDelta(contentIndex: Int, delta: String)
    /// Thinking block ended
    case thinkingEnd(contentIndex: Int, content: ThinkingContent)
    /// Tool call started
    case toolCallStart(contentIndex: Int, partial: ToolCall)
    /// Tool call argument delta
    case toolCallDelta(contentIndex: Int, delta: String)
    /// Tool call ended
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall)
    /// Generation done
    case done(reason: StopReason, message: AssistantMessage)
    /// Error occurred
    case error(reason: StopReason, error: Error)
}

// MARK: - Event Stream

/// An async sequence of AssistantMessageEvents with a final result
public final class AssistantMessageEventStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = AssistantMessageEvent

    private let stream: AsyncStream<AssistantMessageEvent>
    private let continuation: AsyncStream<AssistantMessageEvent>.Continuation
    private var _result: AssistantMessage?
    private var _error: Error?
    private let lock = NSLock()
    private var resultContinuations: [CheckedContinuation<AssistantMessage, Error>] = []

    public init() {
        var cont: AsyncStream<AssistantMessageEvent>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    /// Push an event into the stream
    public func push(_ event: AssistantMessageEvent) {
        continuation.yield(event)
        // Track completion
        switch event {
        case .done(_, let message):
            lock.lock()
            _result = message
            let waiters = resultContinuations
            resultContinuations.removeAll()
            lock.unlock()
            continuation.finish()
            for waiter in waiters {
                waiter.resume(returning: message)
            }
        case .error(_, let error):
            lock.lock()
            _error = error
            let waiters = resultContinuations
            resultContinuations.removeAll()
            lock.unlock()
            continuation.finish()
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
        default:
            break
        }
    }

    /// Abort the stream
    public func abort() {
        push(.error(reason: .aborted, error: StreamError.aborted))
    }

    /// Wait for the final result
    public func result() async throws -> AssistantMessage {
        lock.lock()
        if let r = _result {
            lock.unlock()
            return r
        }
        if let e = _error {
            lock.unlock()
            throw e
        }
        lock.unlock()

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let r = _result {
                lock.unlock()
                cont.resume(returning: r)
            } else if let e = _error {
                lock.unlock()
                cont.resume(throwing: e)
            } else {
                resultContinuations.append(cont)
                lock.unlock()
            }
        }
    }

    // AsyncSequence conformance
    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<AssistantMessageEvent>.AsyncIterator

        public mutating func next() async -> AssistantMessageEvent? {
            await iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}

// MARK: - Stream Errors

public enum StreamError: Error, LocalizedError, Sendable {
    case aborted
    case noProvider(api: String)
    case apiError(statusCode: Int, message: String)
    case networkError(underlying: Error)
    case decodingError(message: String)
    case timeout
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case serverError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .aborted: return "Stream aborted"
        case .noProvider(let api): return "No provider found for API: \(api)"
        case .apiError(let code, let msg): return "API error (\(code)): \(msg)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .timeout: return "Request timed out"
        case .rateLimited: return "Rate limited"
        case .overloaded: return "Server overloaded"
        case .serverError(let code, let msg): return "Server error (\(code)): \(msg)"
        }
    }

    /// Whether this error is retryable
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .serverError, .timeout: return true
        default: return false
        }
    }
}
