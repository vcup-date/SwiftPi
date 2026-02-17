import XCTest
@testable import PiAI

final class PiAITests: XCTestCase {

    // MARK: - Type Tests

    func testAnyCodableString() throws {
        let value = AnyCodable("hello")
        XCTAssertEqual(value.stringValue, "hello")
        XCTAssertNil(value.intValue)

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testAnyCodableInt() throws {
        let value = AnyCodable(42)
        XCTAssertEqual(value.intValue, 42)

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.intValue, 42)
    }

    func testAnyCodableBool() throws {
        let value = AnyCodable(true)
        XCTAssertEqual(value.boolValue, true)
    }

    func testAnyCodableDict() throws {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("test"),
            "count": AnyCodable(5)
        ]
        let data = try JSONEncoder().encode(dict)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        XCTAssertEqual(decoded["name"]?.stringValue, "test")
        XCTAssertEqual(decoded["count"]?.intValue, 5)
    }

    // MARK: - Message Tests

    func testUserMessageCreation() {
        let msg = UserMessage(text: "Hello")
        XCTAssertEqual(msg.textContent, "Hello")
        XCTAssertEqual(msg.role, "user")
    }

    func testAssistantMessageCreation() {
        let msg = AssistantMessage(
            content: [.text(TextContent(text: "Hi there"))],
            model: "claude-sonnet-4-5"
        )
        XCTAssertEqual(msg.textContent, "Hi there")
        XCTAssertFalse(msg.hasToolCalls)
    }

    func testAssistantMessageWithToolCalls() {
        let tc = ToolCall(id: "tc-1", name: "read", arguments: ["path": AnyCodable("test.txt")])
        let msg = AssistantMessage(content: [
            .text(TextContent(text: "Let me read that")),
            .toolCall(tc)
        ])
        XCTAssertTrue(msg.hasToolCalls)
        XCTAssertEqual(msg.toolCalls.count, 1)
        XCTAssertEqual(msg.toolCalls.first?.name, "read")
    }

    func testToolResultMessage() {
        let msg = ToolResultMessage(
            toolCallId: "tc-1",
            toolName: "read",
            content: [.text(TextContent(text: "file contents here"))],
            isError: false
        )
        XCTAssertEqual(msg.textContent, "file contents here")
        XCTAssertFalse(msg.isError)
    }

    // MARK: - Model Tests

    func testBuiltinModelsExist() {
        XCTAssertFalse(BuiltinModels.all.isEmpty)
        XCTAssertNotNil(BuiltinModels.find("claude"))
        XCTAssertNotNil(BuiltinModels.find("gpt-4o"))
    }

    func testModelFind() {
        let model = BuiltinModels.find("sonnet")
        XCTAssertNotNil(model)
        XCTAssertTrue(model!.name.contains("Sonnet"))
    }

    // MARK: - Tool Validation

    func testValidateToolArguments() {
        let schema = JSONSchema(
            type: "object",
            properties: [
                "path": JSONSchemaProperty(type: "string"),
                "limit": JSONSchemaProperty(type: "number")
            ],
            required: ["path"]
        )

        // Valid
        let errors1 = validateToolArguments(args: ["path": AnyCodable("test.txt")], schema: schema)
        XCTAssertTrue(errors1.isEmpty)

        // Missing required
        let errors2 = validateToolArguments(args: [:], schema: schema)
        XCTAssertFalse(errors2.isEmpty)
        XCTAssertTrue(errors2.first?.contains("path") ?? false)
    }

    // MARK: - SSE Parser Tests

    func testSSEParserBasic() {
        let parser = SSEParser()
        let events = parser.feed("data: hello world\n\n".data(using: .utf8)!)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "hello world")
    }

    func testSSEParserMultiLine() {
        let parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n".data(using: .utf8)!)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "line1\nline2")
    }

    func testSSEParserWithEvent() {
        let parser = SSEParser()
        let events = parser.feed("event: test\ndata: payload\n\n".data(using: .utf8)!)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "test")
        XCTAssertEqual(events.first?.data, "payload")
    }

    // MARK: - Stream Tests

    func testAssistantMessageEventStream() async {
        let stream = AssistantMessageEventStream()

        let msg = AssistantMessage(
            content: [.text(TextContent(text: "Hello"))],
            stopReason: .stop
        )

        Task {
            stream.push(.start(partial: msg))
            stream.push(.done(reason: .stop, message: msg))
        }

        let result = try? await stream.result()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.textContent, "Hello")
    }

    // MARK: - API Key Manager

    func testAPIKeyManager() {
        let manager = APIKeyManager(keys: [])

        manager.setKey(APIKeyManager.ProviderKey(
            provider: "anthropic",
            name: "test",
            apiKey: "sk-ant-test123",
            isSelected: true
        ))

        XCTAssertEqual(manager.apiKey(for: "anthropic"), "sk-ant-test123")
        XCTAssertNil(manager.apiKey(for: "openai"))

        manager.setKey(APIKeyManager.ProviderKey(
            provider: "anthropic",
            name: "work",
            apiKey: "sk-ant-work456",
            isSelected: false
        ))

        // Still returns the selected one
        XCTAssertEqual(manager.apiKey(for: "anthropic"), "sk-ant-test123")

        // Select the other
        manager.selectKey(provider: "anthropic", name: "work")
        XCTAssertEqual(manager.apiKey(for: "anthropic"), "sk-ant-work456")
    }

    // MARK: - Provider Registry

    func testProviderRegistry() {
        initializePiAI()

        let anthropic = ProviderRegistry.shared.provider(for: .known(.anthropicMessages))
        XCTAssertNotNil(anthropic)

        let openai = ProviderRegistry.shared.provider(for: .known(.openaiResponses))
        XCTAssertNotNil(openai)

        let unknown = ProviderRegistry.shared.provider(for: .custom("unknown"))
        XCTAssertNil(unknown)
    }
}
