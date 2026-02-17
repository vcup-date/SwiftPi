import Foundation

// MARK: - Messages API Provider

public final class AnthropicProvider: LLMProvider, @unchecked Sendable {
    public let api: Api = .known(.anthropicMessages)
    public static let defaultBaseUrl = "https://api.anthropic.com"
    public static let apiVersion = "2023-06-01"

    public init() {}

    public func stream(model: LLMModel, context: Context, options: StreamOptions) -> AssistantMessageEventStream {
        return streamSimple(model: model, context: context, options: SimpleStreamOptions(base: options))
    }

    public func streamSimple(model: LLMModel, context: Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        let eventStream = AssistantMessageEventStream()

        Task {
            do {
                let baseUrl = model.baseUrl ?? Self.defaultBaseUrl
                let url = URL(string: "\(baseUrl)/v1/messages")!

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

                if let apiKey = options.base.apiKey {
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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

                let body = buildRequestBody(model: model, context: context, options: options)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    guard httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await byte in bytes {
                            errorBody.append(Character(UnicodeScalar(byte)))
                        }
                        let error = parseAPIError(statusCode: httpResponse.statusCode, body: errorBody)
                        eventStream.push(.error(reason: .error, error: error))
                        return
                    }
                }

                try await parseSSEStream(bytes: bytes, model: model, eventStream: eventStream)

            } catch {
                eventStream.push(.error(reason: .error, error: StreamError.networkError(underlying: error)))
            }
        }

        return eventStream
    }

    // MARK: - Request Building

    private func buildRequestBody(model: LLMModel, context: Context, options: SimpleStreamOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": options.base.maxTokens ?? model.maxTokens,
            "stream": true
        ]

        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        if let temperature = options.base.temperature {
            body["temperature"] = temperature
        }

        // Messages
        body["messages"] = context.messages.map { convertMessage($0) }

        // Tools
        if let tools = context.tools, !tools.isEmpty {
            body["tools"] = tools.map { convertTool($0) }
        }

        // Thinking/reasoning
        if let reasoning = options.reasoning, reasoning != .off {
            let budgetTokens: Int
            if let budget = options.thinkingBudgets?.budget(for: reasoning) {
                budgetTokens = budget
            } else {
                switch reasoning {
                case .minimal: budgetTokens = 1024
                case .low: budgetTokens = 2048
                case .medium: budgetTokens = 4096
                case .high: budgetTokens = 8192
                case .xhigh: budgetTokens = 32768
                case .off: budgetTokens = 0
                }
            }
            if budgetTokens > 0 {
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": budgetTokens
                ] as [String: Any]
                // When thinking is enabled, temperature must not be set
                body.removeValue(forKey: "temperature")
            }
        }

        return body
    }

    private func convertMessage(_ message: Message) -> [String: Any] {
        switch message {
        case .user(let m):
            switch m.content {
            case .text(let text):
                return ["role": "user", "content": text]
            case .blocks(let blocks):
                let content: [[String: Any]] = blocks.map { block in
                    switch block {
                    case .text(let t):
                        return ["type": "text", "text": t.text]
                    case .image(let img):
                        return [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": img.mimeType,
                                "data": img.data
                            ]
                        ]
                    }
                }
                return ["role": "user", "content": content]
            }

        case .assistant(let m):
            let content: [[String: Any]] = m.content.map { block in
                switch block {
                case .text(let t):
                    var d: [String: Any] = ["type": "text", "text": t.text]
                    if let sig = t.textSignature { d["text_signature"] = sig }
                    return d
                case .thinking(let t):
                    var d: [String: Any] = ["type": "thinking", "thinking": t.thinking]
                    if let sig = t.thinkingSignature { d["thinking_signature"] = sig }
                    return d
                case .toolCall(let tc):
                    var d: [String: Any] = [
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                        "input": tc.arguments.mapValues { $0.value }
                    ]
                    if let sig = tc.thoughtSignature { d["thought_signature"] = sig }
                    return d
                }
            }
            return ["role": "assistant", "content": content]

        case .toolResult(let m):
            let content: [[String: Any]] = m.content.map { block in
                switch block {
                case .text(let t):
                    return ["type": "text", "text": t.text]
                case .image(let img):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": img.mimeType,
                            "data": img.data
                        ]
                    ]
                }
            }
            return [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId,
                    "content": content,
                    "is_error": m.isError
                ]]
            ]
        }
    }

    private func convertTool(_ tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = ["type": tool.parameters.type]
        if let props = tool.parameters.properties {
            var propsDict: [String: Any] = [:]
            for (key, prop) in props {
                propsDict[key] = convertSchemaProperty(prop)
            }
            schema["properties"] = propsDict
        }
        if let required = tool.parameters.required {
            schema["required"] = required
        }

        return [
            "name": tool.name,
            "description": tool.description,
            "input_schema": schema
        ]
    }

    private func convertSchemaProperty(_ prop: JSONSchemaProperty) -> [String: Any] {
        var d: [String: Any] = [:]
        if let type = prop.type { d["type"] = type }
        if let desc = prop.propertyDescription { d["description"] = desc }
        if let enums = prop.enumValues { d["enum"] = enums }
        if let min = prop.minimum { d["minimum"] = min }
        if let max = prop.maximum { d["maximum"] = max }
        if let items = prop.items { d["items"] = convertSchemaProperty(items) }
        return d
    }

    // MARK: - SSE Parsing

    private func parseSSEStream(bytes: URLSession.AsyncBytes, model: LLMModel, eventStream: AssistantMessageEventStream) async throws {
        var message = AssistantMessage(
            api: self.api,
            provider: model.provider,
            model: model.id
        )
        var contentIndex = 0
        var currentToolCallJson = ""

        for await event in SSEStreamReader.events(from: bytes) {
            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String else {
                continue
            }

            switch eventType {
            case "message_start":
                if let msgData = json["message"] as? [String: Any] {
                    if let usageData = msgData["usage"] as? [String: Any] {
                        message.usage = parseUsage(usageData, model: model)
                    }
                }
                eventStream.push(.start(partial: message))

            case "content_block_start":
                if let index = json["index"] as? Int,
                   let blockData = json["content_block"] as? [String: Any],
                   let blockType = blockData["type"] as? String {
                    contentIndex = index
                    switch blockType {
                    case "text":
                        let tc = TextContent(text: "")
                        message.content.append(.text(tc))
                        eventStream.push(.textStart(contentIndex: index, partial: tc))
                    case "thinking":
                        let tc = ThinkingContent(thinking: "")
                        message.content.append(.thinking(tc))
                        eventStream.push(.thinkingStart(contentIndex: index, partial: tc))
                    case "tool_use":
                        let id = blockData["id"] as? String ?? UUID().uuidString
                        let name = blockData["name"] as? String ?? ""
                        let tc = ToolCall(id: id, name: name, arguments: [:])
                        currentToolCallJson = ""
                        message.content.append(.toolCall(tc))
                        eventStream.push(.toolCallStart(contentIndex: index, partial: tc))
                    default:
                        break
                    }
                }

            case "content_block_delta":
                if let index = json["index"] as? Int,
                   let deltaData = json["delta"] as? [String: Any],
                   let deltaType = deltaData["type"] as? String {
                    switch deltaType {
                    case "text_delta":
                        if let text = deltaData["text"] as? String {
                            if case .text(var tc) = message.content[index] {
                                tc.text += text
                                message.content[index] = .text(tc)
                            }
                            eventStream.push(.textDelta(contentIndex: index, delta: text))
                        }
                    case "thinking_delta":
                        if let thinking = deltaData["thinking"] as? String {
                            if case .thinking(var tc) = message.content[index] {
                                tc.thinking += thinking
                                message.content[index] = .thinking(tc)
                            }
                            eventStream.push(.thinkingDelta(contentIndex: index, delta: thinking))
                        }
                    case "input_json_delta":
                        if let partialJson = deltaData["partial_json"] as? String {
                            currentToolCallJson += partialJson
                            eventStream.push(.toolCallDelta(contentIndex: index, delta: partialJson))
                        }
                    default:
                        break
                    }
                }

            case "content_block_stop":
                if let index = json["index"] as? Int, index < message.content.count {
                    switch message.content[index] {
                    case .text(var tc):
                        if let delta = json["delta"] as? [String: Any], let sig = delta["text_signature"] as? String {
                            tc.textSignature = sig
                            message.content[index] = .text(tc)
                        }
                        eventStream.push(.textEnd(contentIndex: index, content: tc))
                    case .thinking(var tc):
                        if let delta = json["delta"] as? [String: Any], let sig = delta["thinking_signature"] as? String {
                            tc.thinkingSignature = sig
                            message.content[index] = .thinking(tc)
                        }
                        eventStream.push(.thinkingEnd(contentIndex: index, content: tc))
                    case .toolCall(var tc):
                        // Parse accumulated JSON
                        if let data = currentToolCallJson.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            tc.arguments = parsed.mapValues { AnyCodable($0) }
                        }
                        message.content[index] = .toolCall(tc)
                        currentToolCallJson = ""
                        eventStream.push(.toolCallEnd(contentIndex: index, toolCall: tc))
                    }
                }

            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let stopReason = delta["stop_reason"] as? String {
                        switch stopReason {
                        case "end_turn", "stop": message.stopReason = .stop
                        case "tool_use": message.stopReason = .toolUse
                        case "max_tokens": message.stopReason = .length
                        default: message.stopReason = .stop
                        }
                    }
                }
                if let usageData = json["usage"] as? [String: Any] {
                    let newUsage = parseUsage(usageData, model: model)
                    message.usage = mergeUsage(message.usage, newUsage)
                }

            case "message_stop":
                eventStream.push(.done(reason: message.stopReason ?? .stop, message: message))

            case "error":
                if let errorData = json["error"] as? [String: Any],
                   let errorMsg = errorData["message"] as? String {
                    let errorType = errorData["type"] as? String ?? "unknown"
                    let error: StreamError
                    if errorType == "overloaded_error" {
                        error = .overloaded
                    } else if errorType == "rate_limit_error" {
                        error = .rateLimited(retryAfter: nil)
                    } else {
                        error = .apiError(statusCode: 0, message: "\(errorType): \(errorMsg)")
                    }
                    eventStream.push(.error(reason: .error, error: error))
                }

            default:
                break
            }
        }
    }

    private func parseUsage(_ data: [String: Any], model: LLMModel) -> Usage {
        let input = data["input_tokens"] as? Int ?? 0
        let output = data["output_tokens"] as? Int ?? 0
        let cacheRead = data["cache_read_input_tokens"] as? Int ?? data["cache_read"] as? Int ?? 0
        let cacheWrite = data["cache_creation_input_tokens"] as? Int ?? data["cache_write"] as? Int ?? 0
        let total = input + output + cacheRead + cacheWrite

        let cost = UsageCost(
            input: Double(input) * model.cost.input / 1_000_000,
            output: Double(output) * model.cost.output / 1_000_000,
            cacheRead: Double(cacheRead) * model.cost.cacheRead / 1_000_000,
            cacheWrite: Double(cacheWrite) * model.cost.cacheWrite / 1_000_000,
            total: Double(input) * model.cost.input / 1_000_000
                + Double(output) * model.cost.output / 1_000_000
                + Double(cacheRead) * model.cost.cacheRead / 1_000_000
                + Double(cacheWrite) * model.cost.cacheWrite / 1_000_000
        )

        return Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, totalTokens: total, cost: cost)
    }

    private func mergeUsage(_ existing: Usage?, _ new: Usage) -> Usage {
        guard let existing else { return new }
        return Usage(
            input: max(existing.input, new.input),
            output: max(existing.output, new.output),
            cacheRead: max(existing.cacheRead, new.cacheRead),
            cacheWrite: max(existing.cacheWrite, new.cacheWrite),
            totalTokens: max(existing.totalTokens, new.totalTokens),
            cost: UsageCost(
                input: max(existing.cost.input, new.cost.input),
                output: max(existing.cost.output, new.cost.output),
                cacheRead: max(existing.cost.cacheRead, new.cost.cacheRead),
                cacheWrite: max(existing.cost.cacheWrite, new.cost.cacheWrite),
                total: max(existing.cost.total, new.cost.total)
            )
        )
    }

    private func parseAPIError(statusCode: Int, body: String) -> StreamError {
        if statusCode == 429 {
            return .rateLimited(retryAfter: nil)
        }
        if statusCode == 529 {
            return .overloaded
        }
        if statusCode >= 500 {
            return .serverError(statusCode: statusCode, message: body)
        }

        // Try to parse JSON error
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return .apiError(statusCode: statusCode, message: message)
        }

        return .apiError(statusCode: statusCode, message: body)
    }
}
