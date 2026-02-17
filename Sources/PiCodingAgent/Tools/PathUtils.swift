import Foundation

// MARK: - Path Utilities

/// Resolve a path relative to a working directory
public func resolvePath(_ path: String, cwd: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath

    if expanded.hasPrefix("/") {
        return expanded
    }

    return (cwd as NSString).appendingPathComponent(expanded)
}

/// Make a path relative to a base directory
public func relativePath(_ path: String, relativeTo base: String) -> String {
    let absPath = (path as NSString).standardizingPath
    let absBase = (base as NSString).standardizingPath

    if absPath.hasPrefix(absBase + "/") {
        return String(absPath.dropFirst(absBase.count + 1))
    }

    return absPath
}
