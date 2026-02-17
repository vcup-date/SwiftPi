import Foundation
import PiAI

// MARK: - Agent Loop

/// Run the agent loop with initial prompts
public func agentLoop(
    prompts: [AgentMessage],
    context: AgentContext,
    config: AgentLoopConfig
) -> AgentEventStream {
    let eventStream = AgentEventStream()

    Task {
        var currentMessages = context.messages + prompts

        eventStream.push(.agentStart)

        await runLoop(
            messages: &currentMessages,
            systemPrompt: context.systemPrompt,
            tools: context.tools,
            config: config,
            eventStream: eventStream
        )

        eventStream.push(.agentEnd(messages: currentMessages))
    }

    return eventStream
}

/// Continue the agent loop from existing context (e.g., after retry or follow-up)
public func agentLoopContinue(
    context: AgentContext,
    config: AgentLoopConfig
) -> AgentEventStream {
    let eventStream = AgentEventStream()

    Task {
        var currentMessages = context.messages

        eventStream.push(.agentStart)

        await runLoop(
            messages: &currentMessages,
            systemPrompt: context.systemPrompt,
            tools: context.tools,
            config: config,
            eventStream: eventStream
        )

        eventStream.push(.agentEnd(messages: currentMessages))
    }

    return eventStream
}

// MARK: - Internal Loop

/// Hard safety limit on agent loop turns to prevent runaway memory growth
private let defaultMaxTurns = 50

private func runLoop(
    messages: inout [AgentMessage],
    systemPrompt: String,
    tools: [AgentTool],
    config: AgentLoopConfig,
    eventStream: AgentEventStream
) async {
    let maxTurns = config.maxTurns ?? defaultMaxTurns
    var totalTurns = 0

    // Outer loop: handles follow-up messages
    var continueLoop = true

    while continueLoop {
        continueLoop = false

        // Inner loop: handles tool calls and steering
        var hasMoreToolCalls = true

        while hasMoreToolCalls {
            hasMoreToolCalls = false

            // Safety: prevent infinite loop from exhausting memory
            totalTurns += 1
            if totalTurns > maxTurns {
                let errMsg = AssistantMessage(
                    api: config.model.api,
                    provider: config.model.provider,
                    model: config.model.id,
                    stopReason: .error,
                    errorMessage: "Agent loop stopped: exceeded \(maxTurns) turns. Use compact or start a new session."
                )
                eventStream.push(.messageEnd(message: errMsg))
                return
            }

            // Convert to LLM messages — only copy if transform is needed
            let llmMessages: [Message]
            if let transform = config.transformContext {
                let contextMessages = await transform(messages)
                llmMessages = config.convertToLlm(contextMessages)
            } else {
                llmMessages = config.convertToLlm(messages)
            }

            // Build tool definitions
            let toolDefs = tools.map { $0.toolDefinition }

            // Build context
            let llmContext = Context(
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                messages: llmMessages,
                tools: toolDefs.isEmpty ? nil : toolDefs
            )

            eventStream.push(.turnStart)

            // Resolve API key
            let apiKey: String?
            if let getKey = config.getApiKey {
                apiKey = await getKey(config.model.provider.description)
            } else {
                apiKey = nil
            }

            // Stream assistant response
            let options = SimpleStreamOptions(
                base: StreamOptions(apiKey: apiKey),
                reasoning: config.reasoning == .off ? nil : config.reasoning,
                thinkingBudgets: config.thinkingBudgets
            )

            let assistantMessage = await streamAssistantResponse(
                model: config.model,
                context: llmContext,
                options: options,
                eventStream: eventStream
            )

            guard let assistantMessage else {
                // Error occurred, stop
                break
            }

            // Append assistant message
            messages.append(.assistant(assistantMessage))

            // Execute tool calls
            var toolResults: [ToolResultMessage] = []

            if assistantMessage.hasToolCalls {
                let results = await executeToolCalls(
                    toolCalls: assistantMessage.toolCalls,
                    tools: tools,
                    config: config,
                    eventStream: eventStream,
                    messages: &messages
                )
                toolResults = results.results

                // Append tool results
                for result in toolResults {
                    messages.append(.toolResult(result))
                }

                // If there were steering messages injected, or tool calls remain, continue inner loop
                if results.hasSteering || assistantMessage.hasToolCalls {
                    hasMoreToolCalls = true
                }
            }

            eventStream.push(.turnEnd(message: assistantMessage, toolResults: toolResults))

            // If no tool calls, check for follow-up messages
            if !assistantMessage.hasToolCalls {
                if let getFollowUp = config.getFollowUpMessages {
                    let followUpMessages = await getFollowUp()
                    if !followUpMessages.isEmpty {
                        messages.append(contentsOf: followUpMessages)
                        continueLoop = true
                    }
                }
            }
        }
    }
}

// MARK: - Stream Assistant Response

/// Minimum interval between UI update pushes (100ms = ~10 updates/sec)
private let streamingUpdateInterval: UInt64 = 100_000_000

private func streamAssistantResponse(
    model: LLMModel,
    context: Context,
    options: SimpleStreamOptions,
    eventStream: AgentEventStream
) async -> AssistantMessage? {
    let stream = PiAI.streamSimple(model: model, context: context, options: options)

    var message = AssistantMessage(api: model.api, provider: model.provider, model: model.id)
    var finalMessage: AssistantMessage?
    var lastUpdateTime = ContinuousClock.now
    var hasPendingUpdate = false

    for await event in stream {
        switch event {
        case .start(let partial):
            message = partial
            eventStream.push(.messageStart(message: message))

        case .textStart(let idx, _):
            ensureContentSlot(&message, index: idx, default: .text(TextContent(text: "")))

        case .textDelta(let idx, let delta):
            if idx < message.content.count, case .text(var tc) = message.content[idx] {
                tc.text += delta
                message.content[idx] = .text(tc)
            }
            hasPendingUpdate = true

        case .textEnd(let idx, let content):
            if idx < message.content.count {
                message.content[idx] = .text(content)
            }
            // Always push on block end
            eventStream.push(.messageUpdate(message: message, event: event))
            hasPendingUpdate = false
            lastUpdateTime = .now

        case .thinkingStart(let idx, _):
            ensureContentSlot(&message, index: idx, default: .thinking(ThinkingContent(thinking: "")))

        case .thinkingDelta(let idx, let delta):
            if idx < message.content.count, case .thinking(var tc) = message.content[idx] {
                tc.thinking += delta
                message.content[idx] = .thinking(tc)
            }
            hasPendingUpdate = true

        case .thinkingEnd(let idx, let content):
            if idx < message.content.count {
                message.content[idx] = .thinking(content)
            }
            eventStream.push(.messageUpdate(message: message, event: event))
            hasPendingUpdate = false
            lastUpdateTime = .now

        case .toolCallStart(let idx, let partial):
            ensureContentSlot(&message, index: idx, default: .toolCall(partial))
            eventStream.push(.messageUpdate(message: message, event: event))
            lastUpdateTime = .now

        case .toolCallDelta:
            // Don't push UI updates for tool call JSON deltas — low value, high cost
            break

        case .toolCallEnd(let idx, let tc):
            if idx < message.content.count {
                message.content[idx] = .toolCall(tc)
            }
            eventStream.push(.messageUpdate(message: message, event: event))
            lastUpdateTime = .now

        case .done(_, let msg):
            finalMessage = msg
            eventStream.push(.messageEnd(message: msg))

        case .error(_, let error):
            let errMsg = AssistantMessage(
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: error.localizedDescription
            )
            eventStream.push(.messageEnd(message: errMsg))
            return nil
        }

        // Throttled UI update: push at most ~10 times/sec for deltas
        if hasPendingUpdate {
            let elapsed = ContinuousClock.now - lastUpdateTime
            if elapsed >= .nanoseconds(Int64(streamingUpdateInterval)) {
                eventStream.push(.messageUpdate(message: message, event: event))
                hasPendingUpdate = false
                lastUpdateTime = .now
            }
        }
    }

    // Flush any remaining pending update
    if hasPendingUpdate {
        eventStream.push(.messageUpdate(message: message, event: .textDelta(contentIndex: 0, delta: "")))
    }

    return finalMessage
}

private func ensureContentSlot(_ message: inout AssistantMessage, index: Int, default block: AssistantContentBlock) {
    while message.content.count <= index {
        message.content.append(block)
    }
}

// MARK: - Tool Execution

private struct ToolExecutionResults {
    var results: [ToolResultMessage]
    var hasSteering: Bool
}

private func executeToolCalls(
    toolCalls: [ToolCall],
    tools: [AgentTool],
    config: AgentLoopConfig,
    eventStream: AgentEventStream,
    messages: inout [AgentMessage]
) async -> ToolExecutionResults {
    var results: [ToolResultMessage] = []
    var hasSteering = false

    for toolCall in toolCalls {
        let toolName = toolCall.name
        let toolCallId = toolCall.id
        let args = toolCall.arguments

        eventStream.push(.toolExecutionStart(
            toolCallId: toolCallId,
            toolName: toolName,
            args: args
        ))

        // Find the tool
        guard let tool = tools.first(where: { $0.name == toolName }) else {
            let errorResult = AgentToolResult.error("Unknown tool: \(toolName)")
            let toolResult = ToolResultMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                content: errorResult.content,
                isError: true
            )
            results.append(toolResult)
            eventStream.push(.toolExecutionEnd(
                toolCallId: toolCallId,
                toolName: toolName,
                result: errorResult,
                isError: true
            ))
            continue
        }

        // Validate arguments
        let validationErrors = validateToolArguments(args: args, schema: tool.parameters)
        if !validationErrors.isEmpty {
            let errorText = "Argument validation failed:\n" + validationErrors.joined(separator: "\n")
            let errorResult = AgentToolResult.error(errorText)
            let toolResult = ToolResultMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                content: errorResult.content,
                isError: true
            )
            results.append(toolResult)
            eventStream.push(.toolExecutionEnd(
                toolCallId: toolCallId,
                toolName: toolName,
                result: errorResult,
                isError: true
            ))
            continue
        }

        // Check tool permission
        if let confirm = config.confirmToolExecution {
            let permission = await confirm(toolName, args)
            if case .deny(let reason) = permission {
                let errorResult = AgentToolResult.error("Blocked: \(reason)")
                let toolResult = ToolResultMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    content: errorResult.content,
                    isError: true
                )
                results.append(toolResult)
                eventStream.push(.toolExecutionEnd(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    result: errorResult,
                    isError: true
                ))
                continue
            }
        }

        // Execute the tool
        do {
            let updateCallback: AgentToolUpdateCallback = { partialResult in
                eventStream.push(.toolExecutionUpdate(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    partialResult: partialResult
                ))
            }

            let result = try await tool.execute(toolCallId, args, updateCallback)
            let toolResult = ToolResultMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                content: result.content,
                isError: false
            )
            results.append(toolResult)
            eventStream.push(.toolExecutionEnd(
                toolCallId: toolCallId,
                toolName: toolName,
                result: result,
                isError: false
            ))
        } catch {
            let errorResult = AgentToolResult.error(error.localizedDescription)
            let toolResult = ToolResultMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                content: errorResult.content,
                isError: true
            )
            results.append(toolResult)
            eventStream.push(.toolExecutionEnd(
                toolCallId: toolCallId,
                toolName: toolName,
                result: errorResult,
                isError: true
            ))
        }

        // Check for steering messages
        if let getSteering = config.getSteeringMessages {
            let steeringMessages = await getSteering()
            if !steeringMessages.isEmpty {
                messages.append(contentsOf: steeringMessages)
                hasSteering = true
                // Skip remaining tool calls
                for remaining in toolCalls.dropFirst(toolCalls.firstIndex(where: { $0.id == toolCallId })! + 1) {
                    let skippedResult = AgentToolResult.text("Tool call skipped due to steering message")
                    let toolResult = ToolResultMessage(
                        toolCallId: remaining.id,
                        toolName: remaining.name,
                        content: skippedResult.content,
                        isError: false
                    )
                    results.append(toolResult)
                }
                break
            }
        }
    }

    return ToolExecutionResults(results: results, hasSteering: hasSteering)
}
