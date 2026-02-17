import SwiftUI
import PiCodingAgent

// MARK: - UI Builder Preview Panel

/// Renders a UINode tree as live SwiftUI inside the app
public struct UIBuilderPanel: View {
    let node: UINode
    let title: String
    let onDismiss: () -> Void

    @State private var textInputs: [String: String] = [:]
    @State private var toggleStates: [String: Bool] = [:]
    @State private var stateVars: [String: String] = [:]
    @State private var lastAction: String?
    @State private var actionFlash = false

    public init(node: UINode, title: String, onDismiss: @escaping () -> Void) {
        self.node = node
        self.title = title
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Rendered content
            ScrollView {
                renderNode(node)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            }

            // Action status bar
            if let action = lastAction {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    Text(action)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(actionFlash ? Color.accentColor.opacity(0.08) : Color.clear)
                .animation(.easeOut(duration: 0.3), value: actionFlash)
            }
        }
        .background(Color(.windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separatorColor), lineWidth: 0.5)
        )
        .cornerRadius(10)
    }

    // MARK: - Action Handler

    /// Process an action string. Supported commands:
    ///   set:var:value    -- set state variable to value
    ///   append:var:value -- append value to state variable
    ///   clear:var        -- clear state variable to ""
    ///   eval:var         -- evaluate math expression in state variable
    ///   increment:var    -- increment numeric state variable by 1
    ///   decrement:var    -- decrement numeric state variable by 1
    ///   toggle:var       -- toggle boolean state variable (true/false)
    /// Multiple commands can be separated by `;`
    private func handleAction(_ actionId: String) {
        let commands = actionId.components(separatedBy: ";")
        for cmd in commands {
            let parts = cmd.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
            guard let verb = parts.first else { continue }

            switch verb {
            case "set" where parts.count >= 3:
                let varName = parts[1]
                let value = parts.dropFirst(2).joined(separator: ":")
                stateVars[varName] = value

            case "append" where parts.count >= 3:
                let varName = parts[1]
                let value = parts.dropFirst(2).joined(separator: ":")
                stateVars[varName, default: ""].append(value)

            case "clear" where parts.count >= 2:
                stateVars[parts[1]] = ""

            case "eval" where parts.count >= 2:
                let varName = parts[1]
                if let expr = stateVars[varName] {
                    stateVars[varName] = evaluateMath(expr)
                }

            case "increment" where parts.count >= 2:
                let varName = parts[1]
                let current = Double(stateVars[varName] ?? "0") ?? 0
                let result = current + 1
                stateVars[varName] = formatNumber(result)

            case "decrement" where parts.count >= 2:
                let varName = parts[1]
                let current = Double(stateVars[varName] ?? "0") ?? 0
                let result = current - 1
                stateVars[varName] = formatNumber(result)

            case "toggle" where parts.count >= 2:
                let varName = parts[1]
                let current = stateVars[varName] == "true"
                stateVars[varName] = (!current) ? "true" : "false"

            default:
                break
            }
        }

        lastAction = actionId
        actionFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            actionFlash = false
        }
    }

    /// Evaluate a math expression string
    private func evaluateMath(_ expr: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
        let sanitized = String(expr.unicodeScalars.filter { allowed.contains($0) })
        guard !sanitized.isEmpty else { return "0" }

        let nsExpr = NSExpression(format: sanitized)
        if let result = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber {
            return formatNumber(result.doubleValue)
        }
        return "Error"
    }

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    // MARK: - Node Renderer

    private func renderNode(_ node: UINode) -> AnyView {
        let raw = renderNodeRaw(node)
        return applyModifiers(raw, node: node)
    }

    private func renderNodeRaw(_ node: UINode) -> AnyView {
        switch node.type {
        case "vstack":
            return AnyView(VStack(
                alignment: horizontalAlignment(node.string("alignment")),
                spacing: node.number("spacing").map { CGFloat($0) } ?? 8
            ) {
                ForEach(node.children) { child in
                    renderNode(child)
                }
            })

        case "hstack":
            return AnyView(HStack(
                alignment: verticalAlignment(node.string("alignment")),
                spacing: node.number("spacing").map { CGFloat($0) } ?? 8
            ) {
                ForEach(node.children) { child in
                    renderNode(child)
                }
            })

        case "zstack":
            return AnyView(ZStack {
                ForEach(node.children) { child in
                    renderNode(child)
                }
            })

        case "grid":
            let columns = Int(node.number("columns") ?? 4)
            let spacing = node.number("spacing").map { CGFloat($0) } ?? 6
            let gridColumns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
            return AnyView(LazyVGrid(columns: gridColumns, spacing: spacing) {
                ForEach(node.children) { child in
                    renderNode(child)
                }
            })

        case "text":
            let bindKey = node.string("bind")
            let content = bindKey.map { stateVars[$0] ?? "" } ?? (node.string("content") ?? "")
            let isBold = node.bool("bold") ?? false
            let alignment = resolveTextAlignment(node.string("alignment"))
            return AnyView(Text(content)
                .font(resolveFont(node.string("font"), size: node.number("fontSize")))
                .fontWeight(isBold ? .bold : nil)
                .fontDesign(node.string("design") == "monospaced" ? .monospaced : node.string("design") == "rounded" ? .rounded : nil)
                .foregroundColor(resolveColor(node.string("color")))
                .multilineTextAlignment(alignment)
                .lineLimit(node.bool("wrap") == true ? nil : 1)
                .truncationMode(.tail))

        case "button":
            return makeButton(node: node)

        case "textfield":
            let placeholder = node.string("placeholder") ?? ""
            let fieldId = node.string("id") ?? UUID().uuidString
            return AnyView(TextField(placeholder, text: binding(for: fieldId))
                .textFieldStyle(.roundedBorder))

        case "image":
            let systemName = node.string("systemName") ?? "questionmark"
            let size = node.number("size").map { CGFloat($0) }
            return AnyView(Image(systemName: systemName)
                .font(resolveFont(node.string("font"), size: node.number("fontSize")))
                .imageScale(size != nil ? .large : .medium)
                .foregroundColor(resolveColor(node.string("color")))
                .frame(width: size, height: size))

        case "label":
            let text = node.string("content") ?? node.string("label") ?? ""
            let systemName = node.string("systemName") ?? "circle"
            return AnyView(Label(text, systemImage: systemName)
                .font(resolveFont(node.string("font"), size: node.number("fontSize")))
                .foregroundColor(resolveColor(node.string("color"))))

        case "divider":
            return AnyView(Divider())

        case "spacer":
            let minLength = node.number("minLength").map { CGFloat($0) }
            return AnyView(Spacer(minLength: minLength))

        case "rectangle":
            let color = resolveColor(node.string("color")) ?? .accentColor
            let w = node.number("width").map { CGFloat($0) }
            let h = node.number("height").map { CGFloat($0) }
            let cr = node.number("cornerRadius").map { CGFloat($0) } ?? 0
            return AnyView(RoundedRectangle(cornerRadius: cr)
                .fill(color)
                .frame(width: w, height: h))

        case "toggle":
            let label = node.string("label") ?? "Toggle"
            let toggleId = node.string("id") ?? UUID().uuidString
            return AnyView(Toggle(label, isOn: toggleBinding(for: toggleId)))

        case "progress":
            if let value = node.number("value") {
                return AnyView(ProgressView(value: value))
            } else {
                return AnyView(ProgressView())
            }

        case "scroll":
            let axis: Axis.Set = node.string("axis") == "horizontal" ? .horizontal : .vertical
            return AnyView(ScrollView(axis) {
                ForEach(node.children) { child in
                    renderNode(child)
                }
            })

        case "list":
            return AnyView(VStack(spacing: 0) {
                ForEach(node.children) { child in
                    VStack(spacing: 0) {
                        renderNode(child)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                        Divider()
                    }
                }
            }
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8))

        case "padding":
            let value = node.number("value").map { CGFloat($0) } ?? 12
            let edges = resolveEdges(node.string("edges"))
            return AnyView(VStack {
                ForEach(node.children) { child in
                    renderNode(child)
                }
            }
            .padding(edges, value))

        case "section":
            let header = node.string("header") ?? ""
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                if !header.isEmpty {
                    Text(header)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.children) { child in
                        renderNode(child)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(8)
            })

        default:
            return AnyView(Text("Unknown: \(node.type)")
                .font(.caption)
                .foregroundColor(.red))
        }
    }

    // MARK: - Universal Modifiers

    private func applyModifiers(_ view: AnyView, node: UINode) -> AnyView {
        var v = view

        // Self-padding
        if let p = node.number("padding") {
            v = AnyView(v.padding(CGFloat(p)))
        }

        // Background color
        if let bg = node.string("background"), let color = resolveColor(bg) {
            v = AnyView(v.background(color))
        }

        // Border
        if let borderColor = node.string("borderColor"), let color = resolveColor(borderColor) {
            let borderWidth = node.number("borderWidth").map { CGFloat($0) } ?? 1
            let cr = node.number("cornerRadius").map { CGFloat($0) } ?? 0
            v = AnyView(v.overlay(
                RoundedRectangle(cornerRadius: cr)
                    .stroke(color, lineWidth: borderWidth)
            ))
        }

        // Corner radius
        if let cr = node.number("cornerRadius") {
            v = AnyView(v.clipShape(RoundedRectangle(cornerRadius: CGFloat(cr))))
        }

        // Frame sizing
        let w = node.number("width").map { CGFloat($0) }
        let h = node.number("height").map { CGFloat($0) }
        let minH = node.number("minHeight").map { CGFloat($0) }
        let maxW = node.number("maxWidth").map { CGFloat($0) }
        let expand = node.bool("expand") ?? false

        if w != nil || h != nil || maxW != nil || minH != nil || expand {
            v = AnyView(v.frame(
                minHeight: minH,
                maxHeight: h != nil ? nil : (minH != nil ? .infinity : nil)
            ).frame(
                width: w,
                height: h,
                alignment: .center
            ).frame(
                maxWidth: expand ? .infinity : maxW
            ))
        }

        // Opacity
        if let op = node.number("opacity") {
            v = AnyView(v.opacity(op))
        }

        // Shadow
        if let shadowRadius = node.number("shadowRadius") {
            let shadowColor = resolveColor(node.string("shadowColor")) ?? Color(.sRGBLinear, white: 0, opacity: 0.15)
            v = AnyView(v.shadow(color: shadowColor, radius: CGFloat(shadowRadius), y: CGFloat(shadowRadius / 2)))
        }

        return v
    }

    // MARK: - Button Builder

    private func makeButton(node: UINode) -> AnyView {
        let label = node.string("label") ?? "Button"
        let actionId = node.string("action") ?? "tap"
        let style = node.string("style") ?? "bordered"
        let font = resolveFont(node.string("font"), size: node.number("fontSize"))
        let color = resolveColor(node.string("color"))
        let expand = node.bool("expand") ?? false
        let minH = node.number("minHeight").map { CGFloat($0) }
        let systemName = node.string("systemName")

        let buttonLabel: AnyView
        if let systemName {
            buttonLabel = AnyView(Label(label, systemImage: systemName).font(font))
        } else {
            buttonLabel = AnyView(Text(label).font(font))
        }

        switch style {
        case "borderedProminent":
            return AnyView(
                Button(action: { handleAction(actionId) }) {
                    if expand {
                        buttonLabel.frame(maxWidth: .infinity, minHeight: minH)
                    } else {
                        buttonLabel.frame(minHeight: minH)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(color)
            )
        case "plain":
            return AnyView(
                Button(action: { handleAction(actionId) }) {
                    if expand {
                        buttonLabel.frame(maxWidth: .infinity, minHeight: minH)
                    } else {
                        buttonLabel.frame(minHeight: minH)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(color)
            )
        case "custom":
            // Custom styled button - background + corner radius controlled by node props
            let bg = resolveColor(node.string("background")) ?? Color(.controlBackgroundColor)
            let cr = node.number("cornerRadius").map { CGFloat($0) } ?? 8
            return AnyView(
                Button(action: { handleAction(actionId) }) {
                    if expand {
                        buttonLabel
                            .foregroundColor(color ?? .primary)
                            .frame(maxWidth: .infinity, minHeight: minH ?? 36)
                    } else {
                        buttonLabel
                            .foregroundColor(color ?? .primary)
                            .frame(minHeight: minH ?? 36)
                    }
                }
                .buttonStyle(.plain)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: cr))
            )
        default:
            return AnyView(
                Button(action: { handleAction(actionId) }) {
                    if expand {
                        buttonLabel.frame(maxWidth: .infinity, minHeight: minH)
                    } else {
                        buttonLabel.frame(minHeight: minH)
                    }
                }
                .buttonStyle(.bordered)
                .tint(color)
            )
        }
    }

    // MARK: - Bindings

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { textInputs[id] ?? "" },
            set: { textInputs[id] = $0 }
        )
    }

    private func toggleBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { toggleStates[id] ?? false },
            set: { toggleStates[id] = $0 }
        )
    }

    // MARK: - Resolvers

    private func resolveFont(_ name: String?, size: Double? = nil) -> Font {
        if let size {
            let design: Font.Design = name == "mono" ? .monospaced : name == "rounded" ? .rounded : .default
            return .system(size: CGFloat(size), design: design)
        }
        switch name {
        case "largeTitle": return .largeTitle
        case "title": return .title
        case "title2": return .title2
        case "title3": return .title3
        case "headline": return .headline
        case "subheadline": return .subheadline
        case "caption": return .caption
        case "caption2": return .caption2
        case "footnote": return .footnote
        case "mono": return .system(.body, design: .monospaced)
        case "rounded": return .system(.body, design: .rounded)
        default: return .body
        }
    }

    private func resolveColor(_ name: String?) -> Color? {
        guard let name, !name.isEmpty else { return nil }

        // Hex color support: #RRGGBB or #RRGGBBAA
        if name.hasPrefix("#") {
            return colorFromHex(name)
        }

        switch name {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "yellow": return .yellow
        case "pink": return .pink
        case "white": return .white
        case "gray", "grey": return .gray
        case "secondary": return .secondary
        case "primary": return .primary
        case "accent": return .accentColor
        case "teal": return .teal
        case "mint": return .mint
        case "indigo": return .indigo
        case "cyan": return .cyan
        case "brown": return .brown
        case "clear": return .clear
        // System colors
        case "controlBackground": return Color(.controlBackgroundColor)
        case "windowBackground": return Color(.windowBackgroundColor)
        case "textBackground": return Color(.textBackgroundColor)
        case "separator": return Color(.separatorColor)
        default: return nil
        }
    }

    private func colorFromHex(_ hex: String) -> Color? {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        guard hexStr.count == 6 || hexStr.count == 8 else { return nil }

        var rgbValue: UInt64 = 0
        Scanner(string: hexStr).scanHexInt64(&rgbValue)

        if hexStr.count == 6 {
            return Color(
                red: Double((rgbValue >> 16) & 0xFF) / 255,
                green: Double((rgbValue >> 8) & 0xFF) / 255,
                blue: Double(rgbValue & 0xFF) / 255
            )
        } else {
            return Color(
                red: Double((rgbValue >> 24) & 0xFF) / 255,
                green: Double((rgbValue >> 16) & 0xFF) / 255,
                blue: Double((rgbValue >> 8) & 0xFF) / 255,
                opacity: Double(rgbValue & 0xFF) / 255
            )
        }
    }

    private func horizontalAlignment(_ name: String?) -> HorizontalAlignment {
        switch name {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    private func verticalAlignment(_ name: String?) -> VerticalAlignment {
        switch name {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }

    private func resolveTextAlignment(_ name: String?) -> TextAlignment {
        switch name {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    private func resolveEdges(_ name: String?) -> Edge.Set {
        switch name {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .all
        }
    }
}

// MARK: - UI Preview Window

/// Manages a separate macOS window for UI builder previews
@MainActor
public final class UIPreviewWindow {
    public static let shared = UIPreviewWindow()

    private var window: NSWindow?

    private init() {}

    /// Show or update the preview window with a new UI node
    public func show(node: UINode, title: String) {
        let panel = UIBuilderPanel(
            node: node,
            title: title,
            onDismiss: { [weak self] in
                self?.close()
            }
        )

        let hostingView = NSHostingView(rootView: panel.frame(minWidth: 400, minHeight: 300))

        if let existing = window, existing.isVisible {
            existing.title = "SwiftPi  \(title)"
            existing.contentView = hostingView
        } else {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "SwiftPi  \(title)"
            win.contentView = hostingView
            win.center()
            win.isReleasedWhenClosed = false
            win.titlebarAppearsTransparent = true
            win.backgroundColor = .windowBackgroundColor
            window = win
        }

        window?.makeKeyAndOrderFront(nil)
    }

    /// Close the preview window
    public func close() {
        window?.orderOut(nil)
    }
}
