import XCTest
@testable import PiAI
@testable import PiAgent
@testable import PiCodingAgent

final class PiCodingAgentTests: XCTestCase {

    let testDir = NSTemporaryDirectory() + "SwiftPiTests-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: testDir)
    }

    // MARK: - Path Utils

    func testResolvePath() {
        XCTAssertEqual(resolvePath("/absolute/path", cwd: "/home"), "/absolute/path")
        XCTAssertEqual(resolvePath("relative/path", cwd: "/home"), "/home/relative/path")
        XCTAssertTrue(resolvePath("~/file", cwd: "/home").contains(NSHomeDirectory()))
    }

    func testRelativePath() {
        XCTAssertEqual(relativePath("/home/user/file.txt", relativeTo: "/home/user"), "file.txt")
        XCTAssertEqual(relativePath("/other/file.txt", relativeTo: "/home/user"), "/other/file.txt")
    }

    // MARK: - Read Tool

    func testReadFile() async throws {
        let filePath = (testDir as NSString).appendingPathComponent("test.txt")
        try "Line 1\nLine 2\nLine 3\nLine 4\nLine 5".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await readFile(path: "test.txt", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("Line 1"))
            XCTAssertTrue(t.text.contains("Line 5"))
        }
    }

    func testReadFileWithOffset() async throws {
        let filePath = (testDir as NSString).appendingPathComponent("test.txt")
        try "Line 1\nLine 2\nLine 3\nLine 4\nLine 5".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await readFile(path: "test.txt", cwd: testDir, offset: 3, limit: 2)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("Line 3"))
            XCTAssertTrue(t.text.contains("Line 4"))
            XCTAssertFalse(t.text.contains("Line 1"))
        }
    }

    func testReadFileNotFound() async throws {
        let result = try await readFile(path: "nonexistent.txt", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("not found"))
        }
    }

    // MARK: - Write Tool

    func testWriteFile() throws {
        let result = try writeFile(path: "output.txt", content: "Hello World", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("Successfully"))
        }

        let written = try String(contentsOfFile: (testDir as NSString).appendingPathComponent("output.txt"), encoding: .utf8)
        XCTAssertEqual(written, "Hello World")
    }

    func testWriteFileCreatesDirectories() throws {
        let result = try writeFile(path: "sub/dir/file.txt", content: "nested", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("Successfully"))
        }

        let written = try String(contentsOfFile: (testDir as NSString).appendingPathComponent("sub/dir/file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "nested")
    }

    // MARK: - Edit Tool

    func testEditFile() throws {
        let filePath = (testDir as NSString).appendingPathComponent("edit.txt")
        try "Hello World\nFoo Bar\nBaz Qux".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try editFile(path: "edit.txt", oldString: "Foo Bar", newString: "Changed Line", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("Successfully"))
        }

        let modified = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertTrue(modified.contains("Changed Line"))
        XCTAssertFalse(modified.contains("Foo Bar"))
    }

    func testEditFileNotFound() throws {
        let result = try editFile(path: "missing.txt", oldString: "foo", newString: "bar", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("not found") || t.text.contains("Error"))
        }
    }

    func testEditFileOldStringNotFound() throws {
        let filePath = (testDir as NSString).appendingPathComponent("edit2.txt")
        try "Hello World".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try editFile(path: "edit2.txt", oldString: "nonexistent", newString: "replacement", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("not found") || t.text.contains("Error"))
        }
    }

    func testEditFileMultipleMatches() throws {
        let filePath = (testDir as NSString).appendingPathComponent("edit3.txt")
        try "foo bar foo".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try editFile(path: "edit3.txt", oldString: "foo", newString: "baz", cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("2 times") || t.text.contains("Error"))
        }
    }

    // MARK: - Ls Tool

    func testListDirectory() throws {
        try "a".write(toFile: (testDir as NSString).appendingPathComponent("file_a.txt"), atomically: true, encoding: .utf8)
        try "b".write(toFile: (testDir as NSString).appendingPathComponent("file_b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: (testDir as NSString).appendingPathComponent("subdir"), withIntermediateDirectories: true)

        let result = try listDirectory(cwd: testDir)
        if case .text(let t) = result.content.first {
            XCTAssertTrue(t.text.contains("file_a.txt"))
            XCTAssertTrue(t.text.contains("file_b.txt"))
            XCTAssertTrue(t.text.contains("subdir/"))
        }
    }

    // MARK: - Diff Generation

    func testGenerateUnifiedDiff() {
        let diff = generateUnifiedDiff(
            oldContent: "line 1\nline 2\nline 3",
            newContent: "line 1\nchanged line\nline 3",
            filePath: "test.txt"
        )

        XCTAssertTrue(diff.contains("--- a/test.txt"))
        XCTAssertTrue(diff.contains("+++ b/test.txt"))
        XCTAssertTrue(diff.contains("-line 2"))
        XCTAssertTrue(diff.contains("+changed line"))
    }

    // MARK: - Skills

    func testSkillLoading() throws {
        let skillDir = (testDir as NSString).appendingPathComponent("skills")
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)

        let skillContent = """
        ---
        name: test-skill
        description: A test skill
        ---
        # Test Skill

        This skill does testing things.
        """

        try skillContent.write(toFile: (skillDir as NSString).appendingPathComponent("test-skill.md"), atomically: true, encoding: .utf8)

        let result = loadSkillsFromDir(skillDir, source: .user)
        XCTAssertEqual(result.skills.count, 1)
        XCTAssertEqual(result.skills.first?.name, "test-skill")
        XCTAssertEqual(result.skills.first?.description, "A test skill")
    }

    func testSkillFormatting() {
        let skills = [
            Skill(name: "test", description: "Test skill", content: "body", filePath: "/path", baseDir: "/", source: .user)
        ]

        let xml = formatSkillsForPrompt(skills)
        XCTAssertTrue(xml.contains("The following skills provide specialized instructions for specific tasks."))
        XCTAssertTrue(xml.contains("Use the read tool to load a skill's file when the task matches its description."))
        XCTAssertTrue(xml.contains("<available_skills>"))
        XCTAssertTrue(xml.contains("<name>test</name>"))
        XCTAssertTrue(xml.contains("<description>Test skill</description>"))
        XCTAssertTrue(xml.contains("<location>/path</location>"))
    }

    // MARK: - Prompt Templates

    func testPromptTemplateExpansion() {
        let templates = [
            PromptTemplate(name: "greet", description: "Greeting", content: "Hello $1, welcome to $2!", source: "user", filePath: "/test")
        ]

        let result = expandPromptTemplate("/greet World SwiftPi", templates: templates)
        XCTAssertEqual(result, "Hello World, welcome to SwiftPi!")
    }

    func testPromptTemplateAllArgs() {
        let templates = [
            PromptTemplate(name: "echo", description: "Echo all", content: "You said: $@", source: "user", filePath: "/test")
        ]

        let result = expandPromptTemplate("/echo hello world today", templates: templates)
        XCTAssertEqual(result, "You said: hello world today")
    }

    func testPromptTemplateNoMatch() {
        let result = expandPromptTemplate("/unknown arg", templates: [])
        XCTAssertEqual(result, "/unknown arg")
    }

    func testParseCommandArgs() {
        let args = parseCommandArgs("hello world \"multi word\" 'quoted'")
        XCTAssertEqual(args, ["hello", "world", "multi word", "quoted"])
    }

    // MARK: - System Prompt

    func testBuildSystemPrompt() {
        let prompt = buildSystemPrompt(options: SystemPromptOptions(cwd: testDir))
        XCTAssertTrue(prompt.contains("expert coding assistant operating inside pi"))
        XCTAssertTrue(prompt.contains("- bash: Execute bash commands (ls, grep, find, etc.)"))
        XCTAssertTrue(prompt.contains("- read: Read file contents"))
        XCTAssertTrue(prompt.contains("Prefer grep/find/ls tools over bash for file exploration"))
        XCTAssertTrue(prompt.contains("Be concise in your responses"))
        XCTAssertTrue(prompt.contains("Current working directory: \(testDir)"))
    }

    func testBuildSystemPromptCustom() {
        let prompt = buildSystemPrompt(options: SystemPromptOptions(
            customPrompt: "Custom prompt only",
            appendSystemPrompt: "Extra context"
        ))
        XCTAssertTrue(prompt.contains("Custom prompt only"))
        XCTAssertTrue(prompt.contains("Extra context"))
        XCTAssertTrue(prompt.contains("Current date and time:"))
        XCTAssertTrue(prompt.contains("Current working directory:"))
    }

    // MARK: - Compaction

    func testEstimateTokens() {
        XCTAssertEqual(estimateTokens(""), 1)
        XCTAssertEqual(estimateTokens("Hello World"), 2) // 11 chars / 4 ≈ 2
        XCTAssertGreaterThan(estimateTokens(String(repeating: "a", count: 400)), 50)
    }

    func testShouldCompact() {
        XCTAssertTrue(shouldCompact(contextTokens: 190_000, contextWindow: 200_000, reserveTokens: 16384))
        XCTAssertFalse(shouldCompact(contextTokens: 100_000, contextWindow: 200_000, reserveTokens: 16384))
    }

    func testFindCutPoint() {
        let messages: [AgentMessage] = (0..<100).map { i in
            .user(String(repeating: "word ", count: 100)) // ~500 chars = ~125 tokens each
        }

        let cutPoint = findCutPoint(messages: messages, keepRecentTokens: 2000)
        XCTAssertGreaterThan(cutPoint, 0)
        XCTAssertLessThan(cutPoint, messages.count)
    }

    // MARK: - Session Manager

    func testSessionManagerInMemory() {
        let manager = SessionManager.inMemory(cwd: testDir)

        manager.appendMessage(.user(UserMessage(text: "Hello")))
        manager.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "Hi"))])))

        let ctx = manager.buildContext()
        XCTAssertEqual(ctx.messages.count, 2)
    }

    func testSessionManagerBranching() {
        let manager = SessionManager.inMemory(cwd: testDir)

        manager.appendMessage(.user(UserMessage(text: "Message 1")))
        let afterFirst = manager.leafId!

        manager.appendMessage(.user(UserMessage(text: "Message 2")))

        // Branch back to after first message
        manager.branch(to: afterFirst)
        manager.appendMessage(.user(UserMessage(text: "Message 2b (branched)")))

        let ctx = manager.buildContext()
        // Should have Message 1 and Message 2b
        XCTAssertEqual(ctx.messages.count, 2)
    }

    // MARK: - Model Resolver

    func testResolveModel() {
        let result = resolveModel("gpt-4o")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.model.id, "gpt-4o")
    }

    func testResolveModelPartial() {
        let result = resolveModel("mini")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.model.name.contains("Mini"))
    }

    func testResolveModelWithThinking() {
        let result = resolveModel("o3:high")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.thinkingLevel, .high)
    }

    func testResolveModelUnknown() {
        let result = resolveModel("nonexistent-model-xyz")
        XCTAssertNil(result)
    }

    // MARK: - Settings Manager

    func testSettingsManagerDefaults() {
        let manager = SettingsManager(settings: Settings())
        XCTAssertEqual(manager.defaultThinkingLevel, .off)
        XCTAssertTrue(manager.isCompactionEnabled)
        XCTAssertTrue(manager.isRetryEnabled)
    }

    func testSettingsManagerMutation() {
        let manager = SettingsManager(settings: Settings())
        manager.setDefaultThinkingLevel(.high)
        XCTAssertEqual(manager.defaultThinkingLevel, .high)
    }
}
