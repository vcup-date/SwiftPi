import Foundation
import PiAI

// MARK: - Model Resolver

/// Parsed model with optional thinking level
public struct ParsedModel: Sendable {
    public var model: LLMModel
    public var thinkingLevel: ThinkingLevel?
}

/// Resolve a model string to an LLMModel
public func resolveModel(
    _ query: String,
    from models: [LLMModel] = BuiltinModels.all
) -> ParsedModel? {
    let q = query.trimmingCharacters(in: .whitespaces)

    // Try exact match first
    if let model = findModel(q, in: models) {
        return ParsedModel(model: model, thinkingLevel: nil)
    }

    // Try splitting on last colon for thinking level
    if let lastColon = q.lastIndex(of: ":") {
        let modelPart = String(q[q.startIndex..<lastColon])
        let levelPart = String(q[q.index(after: lastColon)...])

        if let level = ThinkingLevel(rawValue: levelPart),
           let model = findModel(modelPart, in: models) {
            return ParsedModel(model: model, thinkingLevel: level)
        }
    }

    return nil
}

/// Find a model by various matching strategies
public func findModel(_ query: String, in models: [LLMModel]) -> LLMModel? {
    let q = query.lowercased()

    // Exact ID match (case-insensitive)
    if let m = models.first(where: { $0.id.lowercased() == q }) {
        return m
    }

    // Provider/modelId format
    if q.contains("/") {
        let parts = q.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            let provider = String(parts[0])
            let modelId = String(parts[1])
            if let m = models.first(where: {
                $0.provider.description.lowercased() == provider && $0.id.lowercased() == modelId
            }) {
                return m
            }
        }
    }

    // Partial ID match (prefer aliases without date suffix)
    let partialMatches = models.filter { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }

    if partialMatches.count == 1 {
        return partialMatches.first
    }

    // Prefer alias (no date) over dated version
    if let alias = partialMatches.first(where: { !$0.id.contains("-202") }) {
        return alias
    }

    return partialMatches.first
}

/// Resolve multiple model patterns (for scoped models)
public func resolveModelScope(
    patterns: [String],
    models: [LLMModel] = BuiltinModels.all
) -> [ParsedModel] {
    return patterns.compactMap { resolveModel($0, from: models) }
}
