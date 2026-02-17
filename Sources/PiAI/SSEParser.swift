import Foundation

// MARK: - Server-Sent Events Parser

/// Parses SSE (Server-Sent Events) from a byte stream
public final class SSEParser: @unchecked Sendable {
    private var buffer = ""
    private var currentEvent = SSEEvent()

    public init() {}

    /// A single SSE event
    public struct SSEEvent: Sendable {
        public var event: String?
        public var data: String = ""
        public var id: String?
        public var retry: Int?

        public init() {}
    }

    /// Feed bytes into the parser and return any complete events
    public func feed(_ data: Data) -> [SSEEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        buffer += text
        return extractEvents()
    }

    /// Feed a string line into the parser
    public func feedLine(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            // Empty line = dispatch event
            if !currentEvent.data.isEmpty || currentEvent.event != nil {
                let event = currentEvent
                currentEvent = SSEEvent()
                return event
            }
            return nil
        }

        if line.hasPrefix(":") {
            // Comment, ignore
            return nil
        }

        let fieldEnd = line.firstIndex(of: ":") ?? line.endIndex
        let field = String(line[line.startIndex..<fieldEnd])
        var value = ""
        if fieldEnd < line.endIndex {
            let valueStart = line.index(after: fieldEnd)
            if valueStart < line.endIndex && line[valueStart] == " " {
                value = String(line[line.index(after: valueStart)...])
            } else {
                value = String(line[valueStart...])
            }
        }

        switch field {
        case "event":
            currentEvent.event = value
        case "data":
            if !currentEvent.data.isEmpty {
                currentEvent.data += "\n"
            }
            currentEvent.data += value
        case "id":
            currentEvent.id = value
        case "retry":
            currentEvent.retry = Int(value)
        default:
            break
        }

        return nil
    }

    private func extractEvents() -> [SSEEvent] {
        var events: [SSEEvent] = []
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            let lines = block.components(separatedBy: "\n")
            for line in lines {
                if let event = feedLine(line) {
                    events.append(event)
                }
            }
            // Dispatch remaining after block
            if !currentEvent.data.isEmpty || currentEvent.event != nil {
                events.append(currentEvent)
                currentEvent = SSEEvent()
            }
        }
        // Handle \r\n\r\n
        while let range = buffer.range(of: "\r\n\r\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            let lines = block.components(separatedBy: "\r\n")
            for line in lines {
                if let event = feedLine(line) {
                    events.append(event)
                }
            }
            if !currentEvent.data.isEmpty || currentEvent.event != nil {
                events.append(currentEvent)
                currentEvent = SSEEvent()
            }
        }
        return events
    }
}

// MARK: - SSE Stream Reader

/// Reads SSE events from a URLSession response
public struct SSEStreamReader {
    /// Parse SSE events from an async byte stream
    public static func events(from bytes: URLSession.AsyncBytes) -> AsyncStream<SSEParser.SSEEvent> {
        AsyncStream { continuation in
            let task = Task {
                let parser = SSEParser()
                var lineBuffer = ""

                for try await byte in bytes {
                    let char = Character(UnicodeScalar(byte))
                    if char == "\n" {
                        if let event = parser.feedLine(lineBuffer) {
                            continuation.yield(event)
                        }
                        // Check for empty line (double newline)
                        if lineBuffer.isEmpty {
                            // Event boundary already handled by parser
                        }
                        lineBuffer = ""
                    } else if char == "\r" {
                        // Handle \r\n
                        continue
                    } else {
                        lineBuffer.append(char)
                    }
                }

                // Final flush
                if !lineBuffer.isEmpty {
                    if let event = parser.feedLine(lineBuffer) {
                        continuation.yield(event)
                    }
                    if let event = parser.feedLine("") {
                        continuation.yield(event)
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
