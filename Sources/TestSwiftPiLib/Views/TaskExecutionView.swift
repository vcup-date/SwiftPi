import SwiftUI
import PiAI
import PiAgent
import PiCodingAgent

// MARK: - Task Execution View (Event Timeline)

public struct TaskExecutionView: View {
    @ObservedObject var session: AgentSession

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Events Timeline", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(session.events.count) events")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if session.isStreaming {
                    ProgressView()
                        .scaleEffect(0.5)
                }

                Button(action: { session.clearEvents() }) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Clear events")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Events list
            ScrollViewReader { proxy in
                List {
                    ForEach(session.events) { event in
                        EventRow(event: event)
                            .id(event.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: session.events.count) {
                    if let last = session.events.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: AgentEventRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Icon
                Image(systemName: iconForType(event.type))
                    .font(.caption)
                    .foregroundColor(colorForType(event.type))
                    .frame(width: 16)

                // Time
                Text(formatTime(event.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)

                // Type badge
                Text(event.type.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(colorForType(event.type).opacity(0.15))
                    .cornerRadius(3)

                // Message
                Text(event.message)
                    .font(.caption)
                    .lineLimit(expanded ? nil : 1)

                Spacer()

                if event.details != nil {
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Details
            if expanded, let details = event.details {
                Text(details)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconForType(_ type: AgentEventRecord.EventType) -> String {
        switch type {
        case .messageStart: return "bubble.left"
        case .messageEnd: return "bubble.left.fill"
        case .toolStart: return "wrench"
        case .toolUpdate: return "arrow.clockwise"
        case .toolEnd: return "checkmark.circle"
        case .toolError: return "exclamationmark.triangle"
        case .turnStart: return "play.circle"
        case .turnEnd: return "stop.circle"
        case .compaction: return "arrow.triangle.2.circlepath"
        case .retry: return "arrow.clockwise.circle"
        case .error: return "xmark.circle"
        case .info: return "info.circle"
        }
    }

    private func colorForType(_ type: AgentEventRecord.EventType) -> Color {
        switch type {
        case .messageStart, .messageEnd: return .blue
        case .toolStart, .toolUpdate: return .purple
        case .toolEnd: return .green
        case .toolError, .error: return .red
        case .turnStart, .turnEnd: return .orange
        case .compaction: return .yellow
        case .retry: return .orange
        case .info: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}
