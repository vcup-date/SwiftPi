import Foundation
import PiAI
import PiAgent

// MARK: - Extension Loader

/// Load extensions from configured paths
/// Note: In Swift, extensions are compiled code. For dynamic loading,
/// we support two approaches:
/// 1. Swift packages compiled as dynamic libraries (.dylib)
/// 2. JavaScript extensions via JavaScriptCore
public func loadExtensions(
    paths: [String],
    cwd: String
) -> LoadExtensionsResult {
    var extensions: [Extension] = []
    var errors: [(path: String, error: String)] = []

    for path in paths {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)

        // Check if it's a Swift extension manifest
        let manifestPath = (resolved as NSString).appendingPathComponent("extension.json")
        if FileManager.default.fileExists(atPath: manifestPath) {
            do {
                let ext = try loadSwiftExtension(from: resolved, manifestPath: manifestPath)
                extensions.append(ext)
            } catch {
                errors.append((path: path, error: error.localizedDescription))
            }
        } else {
            errors.append((path: path, error: "No extension.json manifest found"))
        }
    }

    return LoadExtensionsResult(extensions: extensions, errors: errors)
}

/// Discover and load extensions from default locations
public func discoverAndLoadExtensions(
    configuredPaths: [String] = [],
    cwd: String,
    agentDir: String? = nil
) -> LoadExtensionsResult {
    var allPaths = configuredPaths
    let defaultAgentDir = agentDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".swiftpi")

    // Global extensions
    let globalDir = (defaultAgentDir as NSString).appendingPathComponent("extensions")
    if let files = try? FileManager.default.contentsOfDirectory(atPath: globalDir) {
        for file in files where !file.hasPrefix(".") {
            let fullPath = (globalDir as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                allPaths.append(fullPath)
            }
        }
    }

    // Project extensions
    let projectDir = (cwd as NSString).appendingPathComponent(".swiftpi/extensions")
    if let files = try? FileManager.default.contentsOfDirectory(atPath: projectDir) {
        for file in files where !file.hasPrefix(".") {
            let fullPath = (projectDir as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                allPaths.append(fullPath)
            }
        }
    }

    return loadExtensions(paths: allPaths, cwd: cwd)
}

// MARK: - Extension Loading Helpers

/// Load a Swift extension from a directory with extension.json manifest
private func loadSwiftExtension(from dir: String, manifestPath: String) throws -> Extension {
    let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))

    guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ExtensionError.invalidManifest("Cannot parse extension.json")
    }

    let name = manifest["name"] as? String ?? (dir as NSString).lastPathComponent

    // For now, create a basic extension from the manifest
    // Full dynamic loading would require compiled Swift packages or JS execution
    var tools: [AgentTool] = []
    var commands: [ExtensionCommand] = []

    // Parse tool definitions from manifest
    if let toolDefs = manifest["tools"] as? [[String: Any]] {
        for toolDef in toolDefs {
            if let toolName = toolDef["name"] as? String,
               let description = toolDef["description"] as? String {
                let tool = AgentTool(
                    name: toolName,
                    label: toolDef["label"] as? String ?? toolName,
                    description: description,
                    parameters: JSONSchema(type: "object"),
                    execute: { _, _, _ in
                        AgentToolResult.error("Extension tool '\(toolName)' requires runtime support")
                    }
                )
                tools.append(tool)
            }
        }
    }

    // Parse command definitions
    if let cmdDefs = manifest["commands"] as? [[String: Any]] {
        for cmdDef in cmdDefs {
            if let cmdName = cmdDef["name"] as? String,
               let description = cmdDef["description"] as? String {
                commands.append(ExtensionCommand(
                    name: cmdName,
                    description: description,
                    handler: { _ in "Extension command '\(cmdName)' requires runtime support" }
                ))
            }
        }
    }

    return Extension(path: dir, name: name, tools: tools, commands: commands)
}

// MARK: - Errors

public enum ExtensionError: Error, LocalizedError {
    case invalidManifest(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let m): return "Invalid extension manifest: \(m)"
        case .loadFailed(let m): return "Extension load failed: \(m)"
        }
    }
}
