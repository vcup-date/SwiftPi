import SwiftUI
import PiAI
import PiAgent
import PiCodingAgent

// MARK: - Main Content View

public struct ContentView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationSplitView {
            // Sidebar with tabs
            sidebar
        } detail: {
            // Main content area
            mainContent
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            toolbarContent
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(AppTab.allCases, selection: $appState.selectedTab) { tab in
            Label(tab.rawValue, systemImage: tab.icon)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 150)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Divider()
                // Status bar
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.agentSession.isStreaming ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(appState.agentSession.model.name)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    if appState.agentSession.thinkingLevel != .off {
                        Text(appState.agentSession.thinkingLevel.rawValue)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch appState.selectedTab {
        case .chat:
            ChatView(session: appState.agentSession)
        case .events:
            TaskExecutionView(session: appState.agentSession)
        case .config:
            ConfigPanel(apiKeyManager: appState.apiKeyManager, session: appState.agentSession)
        case .prompts:
            PromptEditor(session: appState.agentSession)
        case .skills:
            SkillBrowser(session: appState.agentSession)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: { appState.newSession() }) {
                Label("New Session", systemImage: "plus")
            }
            .help("Start a new conversation")
        }

        ToolbarItem(placement: .automatic) {
            if appState.agentSession.isStreaming {
                Button(action: { appState.agentSession.abort() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .foregroundColor(.red)
                }
                .help("Stop generation")
            }
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                ForEach(BuiltinModels.all, id: \.id) { model in
                    Button(action: { appState.agentSession.setModel(model) }) {
                        HStack {
                            Text(model.name)
                            if model.id == appState.agentSession.model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(appState.agentSession.model.name, systemImage: "cpu")
                    .font(.caption)
            }
            .help("Select model")
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    Button(action: { appState.agentSession.setThinkingLevel(level) }) {
                        HStack {
                            Text(level.rawValue.capitalized)
                            if level == appState.agentSession.thinkingLevel {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Thinking: \(appState.agentSession.thinkingLevel.rawValue)", systemImage: "brain")
                    .font(.caption)
            }
            .help("Set thinking level")
        }

    }
}
