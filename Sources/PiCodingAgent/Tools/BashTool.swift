import Foundation
import PiAI
import PiAgent

// MARK: - Bash Tool

/// Execute bash commands with streaming output, timeout, and truncation
public struct BashTool {
    public let cwd: String
    public let maxOutputBytes: Int
    public let defaultTimeout: TimeInterval

    public init(cwd: String, maxOutputBytes: Int = 50 * 1024, defaultTimeout: TimeInterval = 120) {
        self.cwd = cwd
        self.maxOutputBytes = maxOutputBytes
        self.defaultTimeout = defaultTimeout
    }

    public var agentTool: AgentTool {
        let cwd = self.cwd
        let maxBytes = self.maxOutputBytes
        let defaultTimeout = self.defaultTimeout

        return AgentTool(
            name: "bash",
            label: "Bash",
            description: "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "command": JSONSchemaProperty(type: "string", description: "Bash command to execute"),
                    "timeout": JSONSchemaProperty(type: "number", description: "Timeout in seconds (optional, no default timeout)")
                ],
                required: ["command"]
            ),
            execute: { toolCallId, args, onUpdate in
                let command = args["command"]?.stringValue ?? ""
                let timeout = args["timeout"]?.doubleValue ?? defaultTimeout

                return try await executeBash(
                    command: command,
                    cwd: cwd,
                    timeout: timeout,
                    maxBytes: maxBytes,
                    onUpdate: onUpdate
                )
            }
        )
    }
}

/// Execute a bash command and return results
public func executeBash(
    command: String,
    cwd: String,
    timeout: TimeInterval = 120,
    maxBytes: Int = 50 * 1024,
    onUpdate: AgentToolUpdateCallback? = nil
) async throws -> AgentToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    // Set environment
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "dumb"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    var outputData = Data()
    var errorData = Data()
    var truncated = false

    // Read stdout asynchronously
    let stdoutHandle = stdout.fileHandleForReading
    let stderrHandle = stderr.fileHandleForReading

    try process.run()

    // Set up timeout
    let timeoutTask = Task {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if process.isRunning {
            process.terminate()
            // Force kill after 5 seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }
    }

    // Read output
    let readTask = Task.detached {
        let data = stdoutHandle.readDataToEndOfFile()
        return data
    }

    let errTask = Task.detached {
        let data = stderrHandle.readDataToEndOfFile()
        return data
    }

    outputData = await readTask.value
    errorData = await errTask.value

    process.waitUntilExit()
    timeoutTask.cancel()

    let exitCode = process.terminationStatus
    let wasTimedOut = process.terminationReason == .uncaughtSignal

    // Build output string
    var output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    if !errorOutput.isEmpty {
        output += "\n" + errorOutput
    }

    // Truncate if needed
    if output.utf8.count > maxBytes {
        let lines = output.components(separatedBy: "\n")
        var truncatedOutput = ""
        var byteCount = 0
        var lineCount = 0

        // Keep tail (most recent output)
        for line in lines.reversed() {
            let lineBytes = line.utf8.count + 1
            if byteCount + lineBytes > maxBytes { break }
            truncatedOutput = line + "\n" + truncatedOutput
            byteCount += lineBytes
            lineCount += 1
        }

        let skipped = lines.count - lineCount
        if skipped > 0 {
            output = "... (\(skipped) lines truncated) ...\n" + truncatedOutput
            truncated = true
        }
    }

    // Send update
    if let onUpdate {
        onUpdate(AgentToolResult.text(output))
    }

    // Build result
    var resultText = output
    if wasTimedOut {
        resultText += "\n⚠ Command timed out after \(Int(timeout)) seconds"
    }
    if exitCode != 0 && !wasTimedOut {
        resultText += "\n⚠ Exit code: \(exitCode)"
    }

    var details: [String: AnyCodable] = [
        "exitCode": AnyCodable(Int(exitCode)),
        "truncated": AnyCodable(truncated)
    ]
    if wasTimedOut {
        details["timedOut"] = AnyCodable(true)
    }

    return AgentToolResult(
        content: [.text(TextContent(text: resultText))],
        details: details
    )
}
