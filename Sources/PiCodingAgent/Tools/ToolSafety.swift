import Foundation
import PiAI
import PiAgent

// MARK: - Tool Safety

/// Safety level for a tool operation
public enum SafetyLevel: Sendable {
    case safe
    case needsConfirmation(reason: String)
    case blocked(reason: String)
}

/// Checks tool calls for dangerous operations
public struct ToolSafety {

    /// Analyze a tool call and return its safety level
    public static func check(toolName: String, args: [String: AnyCodable], cwd: String) -> SafetyLevel {
        switch toolName {
        case "bash":
            return checkBash(args: args, cwd: cwd)
        case "write":
            return checkWrite(args: args, cwd: cwd)
        case "edit":
            return checkEdit(args: args, cwd: cwd)
        case "applescript":
            return checkAppleScript(args: args)
        default:
            return .safe
        }
    }

    // MARK: - Bash Safety

    private static func checkBash(args: [String: AnyCodable], cwd: String) -> SafetyLevel {
        guard let command = args["command"]?.stringValue else { return .safe }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Blocked — never allow these
        for pattern in blockedBashPatterns {
            if matchesPattern(cmd, pattern: pattern.pattern) {
                return .blocked(reason: pattern.reason)
            }
        }

        // Needs confirmation — dangerous but sometimes legitimate
        for pattern in dangerousBashPatterns {
            if matchesPattern(cmd, pattern: pattern.pattern) {
                return .needsConfirmation(reason: pattern.reason)
            }
        }

        return .safe
    }

    // MARK: - Write Safety

    private static func checkWrite(args: [String: AnyCodable], cwd: String) -> SafetyLevel {
        guard let path = args["path"]?.stringValue else { return .safe }
        let resolved = resolvePath(path, cwd: cwd)

        // Block writing to system directories
        for dir in protectedDirectories {
            if resolved.hasPrefix(dir) && !resolved.hasPrefix(cwd) {
                return .blocked(reason: "Cannot write to system directory: \(dir)")
            }
        }

        // Confirm overwriting existing files
        if FileManager.default.fileExists(atPath: resolved) {
            return .needsConfirmation(reason: "Overwrite existing file: \(path)")
        }

        return .safe
    }

    // MARK: - Edit Safety

    private static func checkEdit(args: [String: AnyCodable], cwd: String) -> SafetyLevel {
        guard let path = args["path"]?.stringValue else { return .safe }
        let resolved = resolvePath(path, cwd: cwd)

        // Block editing system files
        for dir in protectedDirectories {
            if resolved.hasPrefix(dir) && !resolved.hasPrefix(cwd) {
                return .blocked(reason: "Cannot edit system file: \(path)")
            }
        }

        return .safe
    }

    // MARK: - AppleScript Safety

    private static func checkAppleScript(args: [String: AnyCodable]) -> SafetyLevel {
        guard let script = args["script"]?.stringValue else { return .safe }
        let lower = script.lowercased()

        // Block dangerous system operations
        if lower.contains("do shell script") && (lower.contains("rm ") || lower.contains("sudo") || lower.contains("mkfs")) {
            return .blocked(reason: "AppleScript with dangerous shell commands is not allowed")
        }

        // Confirm scripts that run shell commands or send messages
        if lower.contains("do shell script") {
            return .needsConfirmation(reason: "AppleScript will execute a shell command")
        }
        if lower.contains("send message") || lower.contains("outgoing message") {
            return .needsConfirmation(reason: "AppleScript will send a message")
        }
        if lower.contains("delete") {
            return .needsConfirmation(reason: "AppleScript will delete items")
        }

        return .safe
    }

    // MARK: - Pattern Matching

    private static func matchesPattern(_ command: String, pattern: String) -> Bool {
        // Simple word-boundary-aware matching
        let lowered = command.lowercased()
        let pat = pattern.lowercased()

        // Check if pattern appears as a command (not inside a string/path)
        if let range = lowered.range(of: pat) {
            // If it's at the start, or preceded by space/pipe/semicolon/&&/||
            let before = range.lowerBound == lowered.startIndex
                ? true
                : {
                    let prev = lowered[lowered.index(before: range.lowerBound)]
                    return " ;|&\n(".contains(prev)
                }()
            return before
        }
        return false
    }

    // MARK: - Patterns

    private struct DangerPattern {
        let pattern: String
        let reason: String
    }

    private static let blockedBashPatterns: [DangerPattern] = [
        // Disk destruction
        DangerPattern(pattern: "mkfs", reason: "Filesystem formatting is not allowed"),
        DangerPattern(pattern: "dd if=", reason: "Raw disk write is not allowed"),
        DangerPattern(pattern: "fdisk", reason: "Disk partitioning is not allowed"),
        // Fork bomb
        DangerPattern(pattern: ":(){ :|:", reason: "Fork bomb detected"),
        // System shutdown
        DangerPattern(pattern: "shutdown", reason: "System shutdown is not allowed"),
        DangerPattern(pattern: "reboot", reason: "System reboot is not allowed"),
        DangerPattern(pattern: "halt", reason: "System halt is not allowed"),
        DangerPattern(pattern: "init 0", reason: "System shutdown is not allowed"),
        // Recursive permission nuke
        DangerPattern(pattern: "chmod -R 777 /", reason: "Recursive permission change on root is not allowed"),
        DangerPattern(pattern: "chown -R", reason: "Recursive ownership change needs confirmation"),
    ]

    private static let dangerousBashPatterns: [DangerPattern] = [
        // Destructive file operations
        DangerPattern(pattern: "rm -rf", reason: "Recursive force delete"),
        DangerPattern(pattern: "rm -fr", reason: "Recursive force delete"),
        DangerPattern(pattern: "rm -f", reason: "Force delete (no confirmation)"),
        DangerPattern(pattern: "rm -r", reason: "Recursive delete"),
        DangerPattern(pattern: "rmdir", reason: "Directory removal"),
        // Overwriting
        DangerPattern(pattern: "> /", reason: "Overwriting file with redirect"),
        DangerPattern(pattern: "mv /", reason: "Moving files from root"),
        DangerPattern(pattern: "cp -rf", reason: "Force recursive copy (may overwrite)"),
        // Process killing
        DangerPattern(pattern: "kill -9", reason: "Force kill process"),
        DangerPattern(pattern: "killall", reason: "Kill processes by name"),
        DangerPattern(pattern: "pkill", reason: "Kill processes by pattern"),
        // Permissions
        DangerPattern(pattern: "chmod", reason: "Changing file permissions"),
        DangerPattern(pattern: "chown", reason: "Changing file ownership"),
        // Network/download
        DangerPattern(pattern: "curl", reason: "Network request"),
        DangerPattern(pattern: "wget", reason: "Network download"),
        // Package management
        DangerPattern(pattern: "brew install", reason: "Installing package"),
        DangerPattern(pattern: "brew uninstall", reason: "Removing package"),
        DangerPattern(pattern: "pip install", reason: "Installing Python package"),
        DangerPattern(pattern: "npm install -g", reason: "Installing global npm package"),
        // Git destructive
        DangerPattern(pattern: "git push --force", reason: "Force push"),
        DangerPattern(pattern: "git push -f", reason: "Force push"),
        DangerPattern(pattern: "git reset --hard", reason: "Hard reset (discards changes)"),
        DangerPattern(pattern: "git clean -f", reason: "Force clean untracked files"),
        DangerPattern(pattern: "git checkout .", reason: "Discard all changes"),
        // Sudo
        DangerPattern(pattern: "sudo", reason: "Elevated privileges"),
    ]

    private static let protectedDirectories: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",
        "/etc",
        "/var",
        "/private",
    ]
}
