import Foundation
import PiAI
import PiAgent

// MARK: - UI Builder Tool

/// Lets the agent build live UI that renders inside the app.
/// The agent describes the UI as a JSON view tree, and the app renders it with SwiftUI.
public struct UIBuilderTool {

    public init() {}

    public var agentTool: AgentTool {
        AgentTool(
            name: "ui",
            label: "UI Builder",
            description: "Render a live interactive UI inside the app from a JSON view tree. Use the read tool to load ~/.swiftpi/skills/ui-builder.md for the full DSL reference and examples. Structure: {\"type\": \"vstack\", \"props\": {...}, \"children\": [...]}. Button taps are reported back as messages.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "view": JSONSchemaProperty(type: "string", description: "JSON view tree describing the UI to render"),
                    "title": JSONSchemaProperty(type: "string", description: "Title for the UI panel (optional)")
                ],
                required: ["view"]
            ),
            execute: { toolCallId, args, onUpdate in
                let viewJson = args["view"]?.stringValue ?? "{}"
                let title = args["title"]?.stringValue

                // Parse the JSON
                guard let data = viewJson.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .error("Invalid JSON view tree")
                }

                guard let node = UINode.parse(parsed) else {
                    return .error("Could not parse view tree")
                }

                // Post notification so the UI layer can pick it up
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .uiBuilderRender,
                        object: nil,
                        userInfo: [
                            "node": node,
                            "title": title ?? "Preview",
                            "toolCallId": toolCallId
                        ]
                    )
                }

                return .text("UI rendered: \(title ?? "Preview")")
            }
        )
    }
}

// MARK: - Notification

public extension Notification.Name {
    static let uiBuilderRender = Notification.Name("SwiftPi.UIBuilder.Render")
    static let uiBuilderAction = Notification.Name("SwiftPi.UIBuilder.Action")
}

// MARK: - UI Node (View Tree)

/// A node in the view tree that can be rendered by SwiftUI
public final class UINode: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let type: String
    public let props: [String: Any]
    public let children: [UINode]

    public init(type: String, props: [String: Any] = [:], children: [UINode] = []) {
        self.type = type
        self.props = props
        self.children = children
    }

    // Typed prop accessors
    public func string(_ key: String) -> String? { props[key] as? String }
    public func number(_ key: String) -> Double? { props[key] as? Double }
    public func bool(_ key: String) -> Bool? { props[key] as? Bool }

    /// Parse from JSON dictionary
    public static func parse(_ dict: [String: Any]) -> UINode? {
        guard let type = dict["type"] as? String else { return nil }
        let props = dict["props"] as? [String: Any] ?? [:]
        let childDicts = dict["children"] as? [[String: Any]] ?? []
        let children = childDicts.compactMap { parse($0) }
        return UINode(type: type, props: props, children: children)
    }
}
