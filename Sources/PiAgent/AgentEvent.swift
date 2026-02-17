import Foundation
import PiAI

// MARK: - Agent Events

/// Events emitted during agent execution
public enum AgentEvent: Sendable {
    /// Agent started processing
    case agentStart
    /// Agent finished processing
    case agentEnd(messages: [AgentMessage])
    /// A new turn started (each LLM call + tool execution = 1 turn)
    case turnStart
    /// A turn ended
    case turnEnd(message: AssistantMessage, toolResults: [ToolResultMessage])
    /// Assistant message streaming started
    case messageStart(message: AssistantMessage)
    /// Assistant message streaming update
    case messageUpdate(message: AssistantMessage, event: AssistantMessageEvent)
    /// Assistant message streaming ended
    case messageEnd(message: AssistantMessage)
    /// Tool execution started
    case toolExecutionStart(toolCallId: String, toolName: String, args: [String: AnyCodable])
    /// Tool execution partial update
    case toolExecutionUpdate(toolCallId: String, toolName: String, partialResult: AgentToolResult)
    /// Tool execution ended
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
}

// MARK: - Agent Event Stream

/// Async stream of agent events
public final class AgentEventStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = AgentEvent

    private let stream: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private var _finalMessages: [AgentMessage]?
    private let lock = NSLock()
    private var resultContinuations: [CheckedContinuation<[AgentMessage], Never>] = []

    public init() {
        var cont: AsyncStream<AgentEvent>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    /// Push an event
    public func push(_ event: AgentEvent) {
        continuation.yield(event)
        if case .agentEnd(let messages) = event {
            lock.lock()
            _finalMessages = messages
            let waiters = resultContinuations
            resultContinuations.removeAll()
            lock.unlock()
            continuation.finish()
            for w in waiters {
                w.resume(returning: messages)
            }
        }
    }

    /// Finish the stream
    public func finish() {
        continuation.finish()
    }

    /// Wait for the final messages
    public func result() async -> [AgentMessage] {
        lock.lock()
        if let m = _finalMessages {
            lock.unlock()
            return m
        }
        lock.unlock()

        return await withCheckedContinuation { cont in
            lock.lock()
            if let m = _finalMessages {
                lock.unlock()
                cont.resume(returning: m)
            } else {
                resultContinuations.append(cont)
                lock.unlock()
            }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<AgentEvent>.AsyncIterator
        public mutating func next() async -> AgentEvent? {
            await iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}
