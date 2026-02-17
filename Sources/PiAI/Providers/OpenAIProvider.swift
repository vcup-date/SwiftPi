import Foundation

// MARK: - OpenAI Completions/Responses Provider

public final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    public let api: Api
    public static let defaultBaseUrl = "https://api.openai.com/v1"

    /// Create a provider for openai-completions or openai-responses API
    public init(api: Api = .known(.openaiResponses)) {
        self.api = api
    }

    public func stream(model: LLMModel, context: Context, options: StreamOptions) -> AssistantMessageEventStream {
        return streamSimple(model: model, context: context, options: SimpleStreamOptions(base: options))
    }

    public func streamSimple(model: LLMModel, context: Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        let eventStream = AssistantMessageEventStream()

        Task {
            do {
                let isResponses = model.api == .known(.openaiResponses)
                let baseUrl = (model.baseUrl ?? Self.defaultBaseUrl).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let endpoint = isResponses ? "/responses" : "/chat/completions"
                let url = URL(string: "\(baseUrl)\(endpoint)")!

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                if let apiKey = options.base.apiKey {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                if let headers = model.headers {
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
                if let headers = options.base.headers {
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }

                let body: [String: Any]
                if isResponses {
                    body = buildResponsesBody(model: model, context: context, options: options)
                } else {
                    body = buildCompletionsBody(model: model, context: context, options: options)
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    var errorBody = ""
                    for try await byte in bytes {
                        errorBody.append(Character(UnicodeScalar(byte)))
                    }
                    let error = parseOpenAIError(statusCode: httpResponse.statusCode, body: errorBody)
                    eventStream.push(.error(reason: .error, error: error))
                    return
                }

                if isResponses {
                    try await parseResponsesStream(bytes: bytes, model: model, eventStream: eventStream)
                } else {
                    try await parseCompletionsStream(bytes: bytes, model: model, eventStream: eventStream)
                }
            } catch {
                eventStream.push(.error(reason: .error, error: StreamError.networkError(underlying: error)))
            }
        }

        return eventStream
    }

    // MARK: - Chat Completions Request

    private func buildCompletionsBody(model: LLMModel, context: Context, options: SimpleStreamOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        if let maxTokens = options.base.maxTokens ?? Optional(model.maxTokens) {
            body["max_tokens"] = maxTokens
        }

        if let temperature = options.base.temperature {
            body["temperature"] = temperature
        }

        // Reasoning
        if let reasoning = options.reasoning, reasoning != .off, model.reasoning {
            let effort: String
            switch reasoning {
            case .minimal, .low: effort = "low"
            case .medium: effort = "medium"
            case .high, .xhigh: effort = "high"
            case .off: effort = "low"
            }
            body["reasoning_effort"] = effort
        }

        // Messages
        var messages: [[String: Any]] = []
        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for msg in context.messages {
            messages.append(contentsOf: convertCompletionsMessage(msg))
        }
        body["messages"] = messages

        // Tools
        if let tools = context.tools, !tools.isEmpty {
            body["tools"] = tools.map { convertCompletionsTool($0) }
        }

        return body
    }

    private func convertCompletionsMessage(_ message: Message) -> [[String: Any]] {
        switch message {
        case .user(let m):
            switch m.content {
            case .text(let text):
                return [["role": "user", "content": text]]
            case .blocks(let blocks):
                let content: [[String: Any]] = blocks.map { block in
                    switch block {
                    case .text(let t):
                        return ["type": "text", "text": t.text]
                    case .image(let img):
                        return [
                            "type": "image_url",
                            "image_url": ["url": "data:\(img.mimeType);base64,\(img.data)"]
                        ]
                    }
                }
                return [["role": "user", "content": content]]
            }

        case .assistant(let m):
            var msg: [String: Any] = ["role": "assistant"]
            var contentText = ""
            var toolCalls: [[String: Any]] = []

            for block in m.content {
                switch block {
                case .text(let t):
                    contentText += t.text
                case .thinking:
                    break // OpenAI completions doesn't have thinking blocks
                case .toolCall(let tc):
                    let args: String
                    if let data = try? JSONSerialization.data(withJSONObject: tc.arguments.mapValues { $0.value }),
                       let s = String(data: data, encoding: .utf8) {
                        args = s
                    } else {
                        args = "{}"
                    }
                    toolCalls.append([
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": args
                        ]
                    ])
                }
            }

            if !contentText.isEmpty {
                msg["content"] = contentText
            }
            if !toolCalls.isEmpty {
                msg["tool_calls"] = toolCalls
            }
            return [msg]

        case .toolResult(let m):
            return [[
                "role": "tool",
                "tool_call_id": m.toolCallId,
                "content": m.textContent
            ]]
        }
    }

    private func convertCompletionsTool(_ tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = ["type": tool.parameters.type]
        if let props = tool.parameters.properties {
            var propsDict: [String: Any] = [:]
            for (key, prop) in props {
                propsDict[key] = convertProp(prop)
            }
            schema["properties"] = propsDict
        }
        if let required = tool.parameters.required {
            schema["required"] = required
        }

        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": schema
            ]
        ]
    }

    private func convertProp(_ prop: JSONSchemaProperty) -> [String: Any] {
        var d: [String: Any] = [:]
        if let type = prop.type { d["type"] = type }
        if let desc = prop.propertyDescription { d["description"] = desc }
        if let enums = prop.enumValues { d["enum"] = enums }
        if let min = prop.minimum { d["minimum"] = min }
        if let max = prop.maximum { d["maximum"] = max }
        if let items = prop.items { d["items"] = convertProp(items) }
        return d
    }

    // MARK: - Chat Completions Stream Parsing

    private func parseCompletionsStream(bytes: URLSession.AsyncBytes, model: LLMModel, eventStream: AssistantMessageEventStream) async throws {
        var message = AssistantMessage(
            api: self.api,
            provider: model.provider,
            model: model.id
        )
        var toolCallJsonBuffers: [Int: String] = [:]
        var started = false

        for await event in SSEStreamReader.events(from: bytes) {
            if event.data == "[DONE]" {
                // Finalize tool call arguments from accumulated JSON BEFORE pushing done
                finalizeToolCalls(message: &message, buffers: toolCallJsonBuffers, eventStream: eventStream)
                // Close content blocks
                for (idx, block) in message.content.enumerated() {
                    switch block {
                    case .text(let tc):
                        eventStream.push(.textEnd(contentIndex: idx, content: tc))
                    case .thinking(let tc):
                        eventStream.push(.thinkingEnd(contentIndex: idx, content: tc))
                    case .toolCall:
                        break
                    }
                }
                message.stopReason = message.stopReason ?? (message.hasToolCalls ? .toolUse : .stop)
                eventStream.push(.done(reason: message.stopReason!, message: message))
                return
            }

            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Usage info
            if let usageData = json["usage"] as? [String: Any] {
                message.usage = parseOpenAIUsage(usageData, model: model)
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let delta = choice["delta"] as? [String: Any] else {
                continue
            }

            if !started {
                started = true
                eventStream.push(.start(partial: message))
            }

            // Reasoning/thinking content (DeepSeek R1, OpenAI o-series, etc.)
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                if message.content.isEmpty || !isThinkingBlock(message.content.last) {
                    let tc = ThinkingContent(thinking: "")
                    message.content.append(.thinking(tc))
                    eventStream.push(.thinkingStart(contentIndex: message.content.count - 1, partial: tc))
                }
                let idx = message.content.count - 1
                if case .thinking(var tc) = message.content[idx] {
                    tc.thinking += reasoning
                    message.content[idx] = .thinking(tc)
                }
                eventStream.push(.thinkingDelta(contentIndex: idx, delta: reasoning))
            }

            // Text content
            if let content = delta["content"] as? String {
                if message.content.isEmpty || !isTextBlock(message.content.last) {
                    let tc = TextContent(text: "")
                    message.content.append(.text(tc))
                    eventStream.push(.textStart(contentIndex: message.content.count - 1, partial: tc))
                }
                let idx = message.content.count - 1
                if case .text(var tc) = message.content[idx] {
                    tc.text += content
                    message.content[idx] = .text(tc)
                }
                eventStream.push(.textDelta(contentIndex: idx, delta: content))
            }

            // Tool calls
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let tcIndex = tc["index"] as? Int ?? 0

                    if let function = tc["function"] as? [String: Any] {
                        if let name = function["name"] as? String {
                            // New tool call
                            let id = tc["id"] as? String ?? UUID().uuidString
                            let toolCall = ToolCall(id: id, name: name, arguments: [:])
                            toolCallJsonBuffers[tcIndex] = ""
                            message.content.append(.toolCall(toolCall))
                            eventStream.push(.toolCallStart(contentIndex: message.content.count - 1, partial: toolCall))
                        }
                        if let args = function["arguments"] as? String {
                            toolCallJsonBuffers[tcIndex, default: ""] += args
                            let contentIdx = findToolCallContentIndex(message: message, tcIndex: tcIndex)
                            if contentIdx >= 0 {
                                eventStream.push(.toolCallDelta(contentIndex: contentIdx, delta: args))
                            }
                        }
                    }
                }
            }

            // Finish reason
            if let finishReason = choice["finish_reason"] as? String {
                switch finishReason {
                case "stop": message.stopReason = .stop
                case "tool_calls": message.stopReason = .toolUse
                case "length": message.stopReason = .length
                default: message.stopReason = .stop
                }
            }
        }

        // Finalize tool calls
        finalizeToolCalls(message: &message, buffers: toolCallJsonBuffers, eventStream: eventStream)

        // Close text blocks
        for (idx, block) in message.content.enumerated() {
            if case .text(let tc) = block {
                eventStream.push(.textEnd(contentIndex: idx, content: tc))
            }
        }

        message.stopReason = message.stopReason ?? (message.hasToolCalls ? .toolUse : .stop)
        eventStream.push(.done(reason: message.stopReason!, message: message))
    }

    // MARK: - Responses API

    private func buildResponsesBody(model: LLMModel, context: Context, options: SimpleStreamOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "stream": true
        ]

        if let maxTokens = options.base.maxTokens ?? Optional(model.maxTokens) {
            body["max_output_tokens"] = maxTokens
        }

        if let temperature = options.base.temperature {
            body["temperature"] = temperature
        }

        // Reasoning
        if let reasoning = options.reasoning, reasoning != .off, model.reasoning {
            let effort: String
            switch reasoning {
            case .minimal, .low: effort = "low"
            case .medium: effort = "medium"
            case .high, .xhigh: effort = "high"
            case .off: effort = "low"
            }
            body["reasoning"] = ["effort": effort]
        }

        // Build input array
        var input: [Any] = []

        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            input.append([
                "role": "developer",
                "content": systemPrompt
            ])
        }

        for msg in context.messages {
            input.append(contentsOf: convertResponsesMessage(msg))
        }
        body["input"] = input

        // Tools
        if let tools = context.tools, !tools.isEmpty {
            body["tools"] = tools.map { convertResponsesTool($0) }
        }

        return body
    }

    private func convertResponsesMessage(_ message: Message) -> [[String: Any]] {
        switch message {
        case .user(let m):
            return [["role": "user", "content": m.textContent]]
        case .assistant(let m):
            var items: [[String: Any]] = []
            for block in m.content {
                switch block {
                case .text(let t):
                    items.append(["type": "output_text", "text": t.text])
                case .thinking(let t):
                    items.append(["type": "reasoning", "content": [["type": "text", "text": t.thinking]]])
                case .toolCall(let tc):
                    let args: String
                    if let data = try? JSONSerialization.data(withJSONObject: tc.arguments.mapValues { $0.value }),
                       let s = String(data: data, encoding: .utf8) {
                        args = s
                    } else {
                        args = "{}"
                    }
                    items.append([
                        "type": "function_call",
                        "id": tc.id,
                        "name": tc.name,
                        "arguments": args
                    ])
                }
            }
            return items.isEmpty ? [] : [["role": "assistant", "content": items]]
        case .toolResult(let m):
            return [[
                "type": "function_call_output",
                "call_id": m.toolCallId,
                "output": m.textContent
            ]]
        }
    }

    private func convertResponsesTool(_ tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = ["type": tool.parameters.type]
        if let props = tool.parameters.properties {
            var propsDict: [String: Any] = [:]
            for (key, prop) in props {
                propsDict[key] = convertProp(prop)
            }
            schema["properties"] = propsDict
        }
        if let required = tool.parameters.required {
            schema["required"] = required
        }

        return [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": schema
        ]
    }

    private func parseResponsesStream(bytes: URLSession.AsyncBytes, model: LLMModel, eventStream: AssistantMessageEventStream) async throws {
        var message = AssistantMessage(
            api: self.api,
            provider: model.provider,
            model: model.id
        )
        var started = false
        var toolCallJsonBuffers: [String: String] = [:]

        for await event in SSEStreamReader.events(from: bytes) {
            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String else {
                continue
            }

            if !started {
                started = true
                eventStream.push(.start(partial: message))
            }

            switch eventType {
            case "response.output_text.delta":
                let delta = json["delta"] as? String ?? ""
                if message.content.isEmpty || !isTextBlock(message.content.last) {
                    let tc = TextContent(text: "")
                    message.content.append(.text(tc))
                    eventStream.push(.textStart(contentIndex: message.content.count - 1, partial: tc))
                }
                let idx = message.content.count - 1
                if case .text(var tc) = message.content[idx] {
                    tc.text += delta
                    message.content[idx] = .text(tc)
                }
                eventStream.push(.textDelta(contentIndex: idx, delta: delta))

            case "response.output_text.done":
                let idx = message.content.count - 1
                if idx >= 0, case .text(let tc) = message.content[idx] {
                    eventStream.push(.textEnd(contentIndex: idx, content: tc))
                }

            case "response.function_call_arguments.delta":
                let delta = json["delta"] as? String ?? ""
                let callId = json["call_id"] as? String ?? ""
                toolCallJsonBuffers[callId, default: ""] += delta
                let idx = findToolCallById(message: message, id: callId)
                if idx >= 0 {
                    eventStream.push(.toolCallDelta(contentIndex: idx, delta: delta))
                }

            case "response.function_call_arguments.done":
                let callId = json["call_id"] as? String ?? ""
                let idx = findToolCallById(message: message, id: callId)
                if idx >= 0, case .toolCall(var tc) = message.content[idx] {
                    if let jsonStr = toolCallJsonBuffers[callId],
                       let jsonData = jsonStr.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        tc.arguments = parsed.mapValues { AnyCodable($0) }
                        message.content[idx] = .toolCall(tc)
                    }
                    eventStream.push(.toolCallEnd(contentIndex: idx, toolCall: tc))
                }

            case "response.output_item.added":
                if let item = json["item"] as? [String: Any], let itemType = item["type"] as? String {
                    if itemType == "function_call" {
                        let id = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
                        let name = item["name"] as? String ?? ""
                        let tc = ToolCall(id: id, name: name, arguments: [:])
                        toolCallJsonBuffers[id] = ""
                        message.content.append(.toolCall(tc))
                        eventStream.push(.toolCallStart(contentIndex: message.content.count - 1, partial: tc))
                    }
                }

            case "response.reasoning.delta":
                let delta = json["delta"] as? String ?? ""
                if message.content.isEmpty || !isThinkingBlock(message.content.last) {
                    let tc = ThinkingContent(thinking: "")
                    message.content.append(.thinking(tc))
                    eventStream.push(.thinkingStart(contentIndex: message.content.count - 1, partial: tc))
                }
                let idx = message.content.count - 1
                if case .thinking(var tc) = message.content[idx] {
                    tc.thinking += delta
                    message.content[idx] = .thinking(tc)
                }
                eventStream.push(.thinkingDelta(contentIndex: idx, delta: delta))

            case "response.reasoning.done":
                let idx = message.content.count - 1
                if idx >= 0, case .thinking(let tc) = message.content[idx] {
                    eventStream.push(.thinkingEnd(contentIndex: idx, content: tc))
                }

            case "response.completed":
                if let resp = json["response"] as? [String: Any],
                   let usageData = resp["usage"] as? [String: Any] {
                    message.usage = parseOpenAIUsage(usageData, model: model)
                }
                message.stopReason = message.hasToolCalls ? .toolUse : .stop
                eventStream.push(.done(reason: message.stopReason!, message: message))
                return

            case "error":
                let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                eventStream.push(.error(reason: .error, error: StreamError.apiError(statusCode: 0, message: msg)))
                return

            default:
                break
            }
        }

        // If stream ends without response.completed
        if message.stopReason == nil {
            message.stopReason = message.hasToolCalls ? .toolUse : .stop
            eventStream.push(.done(reason: message.stopReason!, message: message))
        }
    }

    // MARK: - Helpers

    private func isTextBlock(_ block: AssistantContentBlock?) -> Bool {
        guard let block else { return false }
        if case .text = block { return true }
        return false
    }

    private func isThinkingBlock(_ block: AssistantContentBlock?) -> Bool {
        guard let block else { return false }
        if case .thinking = block { return true }
        return false
    }

    private func findToolCallContentIndex(message: AssistantMessage, tcIndex: Int) -> Int {
        var count = 0
        for (idx, block) in message.content.enumerated() {
            if case .toolCall = block {
                if count == tcIndex { return idx }
                count += 1
            }
        }
        return -1
    }

    private func findToolCallById(message: AssistantMessage, id: String) -> Int {
        for (idx, block) in message.content.enumerated() {
            if case .toolCall(let tc) = block, tc.id == id {
                return idx
            }
        }
        return -1
    }

    private func finalizeToolCalls(message: inout AssistantMessage, buffers: [Int: String], eventStream: AssistantMessageEventStream) {
        var tcCount = 0
        for (idx, block) in message.content.enumerated() {
            if case .toolCall(var tc) = block {
                if let jsonStr = buffers[tcCount],
                   let data = jsonStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    tc.arguments = parsed.mapValues { AnyCodable($0) }
                    message.content[idx] = .toolCall(tc)
                }
                eventStream.push(.toolCallEnd(contentIndex: idx, toolCall: tc))
                tcCount += 1
            }
        }
    }

    private func parseOpenAIUsage(_ data: [String: Any], model: LLMModel) -> Usage {
        let input = data["input_tokens"] as? Int ?? data["prompt_tokens"] as? Int ?? 0
        let output = data["output_tokens"] as? Int ?? data["completion_tokens"] as? Int ?? 0
        let total = data["total_tokens"] as? Int ?? (input + output)

        let cost = UsageCost(
            input: Double(input) * model.cost.input / 1_000_000,
            output: Double(output) * model.cost.output / 1_000_000,
            total: Double(input) * model.cost.input / 1_000_000 + Double(output) * model.cost.output / 1_000_000
        )

        return Usage(input: input, output: output, totalTokens: total, cost: cost)
    }

    private func parseOpenAIError(statusCode: Int, body: String) -> StreamError {
        if statusCode == 429 { return .rateLimited(retryAfter: nil) }
        if statusCode >= 500 { return .serverError(statusCode: statusCode, message: body) }

        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return .apiError(statusCode: statusCode, message: message)
        }

        return .apiError(statusCode: statusCode, message: body)
    }
}
