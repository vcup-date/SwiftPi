import XCTest
@testable import PiAI
@testable import PiAgent

final class PiAgentTests: XCTestCase {

    // MARK: - Agent Message Tests

    func testAgentMessageUser() {
        let msg = AgentMessage.user("Hello")
        XCTAssertNotNil(msg.id)
        if case .message(.user(let m)) = msg {
            XCTAssertEqual(m.textContent, "Hello")
        } else {
            XCTFail("Expected user message")
        }
    }

    func testAgentMessageCustom() {
        let custom = CustomAgentMessage(type: "bash_execution", data: ["command": AnyCodable("ls")])
        let msg = AgentMessage.custom(custom)
        XCTAssertNil(msg.asMessage)
        if case .custom(let c) = msg {
            XCTAssertEqual(c.type, "bash_execution")
        }
    }

    // MARK: - Agent Tool Tests

    func testAgentToolResult() {
        let result = AgentToolResult.text("Hello result")
        XCTAssertEqual(result.content.count, 1)
        if case .text(let t) = result.content.first {
            XCTAssertEqual(t.text, "Hello result")
        }
    }

    func testAgentToolResultError() {
        let result = AgentToolResult.error("Something went wrong")
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("Error"))
        }
    }

    // MARK: - Agent Tool Definition

    func testAgentToolDefinition() {
        let tool = AgentTool(
            name: "test",
            label: "Test",
            description: "A test tool",
            parameters: JSONSchema(
                type: "object",
                properties: ["input": JSONSchemaProperty(type: "string")],
                required: ["input"]
            ),
            execute: { _, args, _ in
                let input = args["input"]?.stringValue ?? ""
                return AgentToolResult.text("Got: \(input)")
            }
        )

        XCTAssertEqual(tool.name, "test")
        XCTAssertEqual(tool.toolDefinition.name, "test")
    }

    func testAgentToolExecution() async throws {
        let tool = AgentTool(
            name: "echo",
            label: "Echo",
            description: "Echoes input",
            parameters: JSONSchema(type: "object"),
            execute: { _, args, _ in
                let msg = args["message"]?.stringValue ?? "no message"
                return AgentToolResult.text("Echo: \(msg)")
            }
        )

        let result = try await tool.execute("tc-1", ["message": AnyCodable("hello")], nil)
        if case .text(let t) = result.content.first {
            XCTAssertEqual(t.text, "Echo: hello")
        }
    }

    // MARK: - Default Convert To LLM

    func testDefaultConvertToLlm() {
        let messages: [AgentMessage] = [
            .user("Hello"),
            .custom(CustomAgentMessage(type: "internal", data: [:])),
            .message(.assistant(AssistantMessage(content: [.text(TextContent(text: "Hi"))])))
        ]

        let llmMessages = defaultConvertToLlm(messages)
        XCTAssertEqual(llmMessages.count, 2) // Custom message filtered out
    }

    // MARK: - Agent State

    func testAgentStateInitialization() {
        let state = AgentState(model: LLMModel(id: "test", name: "Test", api: .known(.openaiCompletions), provider: .known(.openai)))
        XCTAssertEqual(state.systemPrompt, "")
        XCTAssertFalse(state.isStreaming)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.tools.isEmpty)
        XCTAssertNil(state.error)
    }

    // MARK: - Agent Event Stream

    func testAgentEventStream() async {
        let stream = AgentEventStream()

        Task {
            stream.push(.agentStart)
            stream.push(.turnStart)
            stream.push(.turnEnd(
                message: AssistantMessage(content: [.text(TextContent(text: "Hi"))]),
                toolResults: []
            ))
            stream.push(.agentEnd(messages: [.user("Hello")]))
        }

        let result = await stream.result()
        XCTAssertEqual(result.count, 1)
    }
}
