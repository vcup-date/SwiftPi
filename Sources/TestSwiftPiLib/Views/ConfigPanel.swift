import SwiftUI
import PiAI
import PiAgent
import PiCodingAgent

// MARK: - Config Panel

public struct ConfigPanel: View {
    @ObservedObject var apiKeyManager: APIKeyManager
    @ObservedObject var session: AgentSession
    @State private var newKeyProvider = ""
    @State private var newKeyName = ""
    @State private var newKeyValue = ""
    @State private var newKeyBaseUrl = ""
    @State private var showAddKey = false
    @State private var customModelId = ""
    @State private var customModelApi: Api = .known(.openaiResponses)
    @State private var customContextWindow = "200000"
    @State private var customMaxTokens = "16384"

    // Well-known providers with their base URLs
    private static let knownProviders: [(name: String, baseUrl: String?)] = [
        ("openai", nil),
        ("openrouter", "https://openrouter.ai/api/v1"),
        ("together", "https://api.together.xyz/v1"),
        ("groq", "https://api.groq.com/openai/v1"),
        ("fireworks", "https://api.fireworks.ai/inference/v1"),
        ("deepseek", "https://api.deepseek.com/v1"),
        ("mistral", "https://api.mistral.ai/v1"),
        ("ollama", "http://localhost:11434/v1"),
    ]

    public init(apiKeyManager: APIKeyManager, session: AgentSession) {
        self.apiKeyManager = apiKeyManager
        self.session = session
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Model Selection
                modelSection

                // Thinking Level
                thinkingSection

                // API Keys
                apiKeysSection

                // Settings
                settingsSection
            }
            .padding()
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Model", systemImage: "cpu")
                .font(.headline)

            // Model ID — the main thing, type anything
            HStack(spacing: 8) {
                Text("Model ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
                TextField("e.g. openai/gpt-4o, meta-llama/llama-3-70b, deepseek/deepseek-r1", text: $customModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onAppear { syncFromSession() }
            }

            // API format — how to talk to the endpoint
            HStack(spacing: 8) {
                Text("API format")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Picker("", selection: $customModelApi) {
                    Text("OpenAI Responses").tag(Api.known(.openaiResponses))
                    Text("OpenAI Chat Completions").tag(Api.known(.openaiCompletions))
                    Text("Messages API").tag(Api.known(.anthropicMessages))
                }
                .pickerStyle(.segmented)
            }

            // Context + Max tokens
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Context")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    TextField("200000", text: $customContextWindow)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                HStack(spacing: 8) {
                    Text("Max output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("16384", text: $customMaxTokens)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }

            // Apply
            HStack {
                Button("Apply Model") {
                    applyCustomModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(customModelId.isEmpty)

                Spacer()

                // Current active model
                Text("Active: \(session.model.id)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

        }
    }

    private func applyCustomModel() {
        // Determine provider from selected API key or model ID
        let selectedKey = apiKeyManager.keys.first(where: { $0.isSelected })
        let baseUrl = selectedKey?.baseUrl
        let providerName = selectedKey?.provider ?? "openai"
        let provider: Provider
        switch providerName {
        case "openai": provider = .known(.openai)
        case "google": provider = .known(.google)
        default: provider = .custom(providerName)
        }

        // Check if it matches a builtin (and no custom base URL)
        if baseUrl == nil, let builtin = BuiltinModels.all.first(where: { $0.id == customModelId }) {
            var model = builtin
            if let ctx = Int(customContextWindow) { model.contextWindow = ctx }
            if let max = Int(customMaxTokens) { model.maxTokens = max }
            model.api = customModelApi
            session.setModel(model)
        } else {
            let model = LLMModel(
                id: customModelId,
                name: customModelId,
                api: customModelApi,
                provider: provider,
                baseUrl: baseUrl,
                reasoning: false,
                inputModalities: ["text", "image"],
                contextWindow: Int(customContextWindow) ?? 128_000,
                maxTokens: Int(customMaxTokens) ?? 16_384
            )
            session.setModel(model)
        }
    }

    // MARK: - Thinking Section

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Thinking Level", systemImage: "brain")
                .font(.headline)

            Picker("Level", selection: Binding(
                get: { session.thinkingLevel },
                set: { session.setThinkingLevel($0) }
            )) {
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("API Keys", systemImage: "key")
                    .font(.headline)
                Spacer()
                Button(action: { showAddKey.toggle() }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            // List existing keys
            ForEach(apiKeyManager.keys) { key in
                APIKeyRow(
                    key: key,
                    isSelected: key.isSelected,
                    onSelect: {
                        apiKeyManager.selectKey(provider: key.provider, name: key.name)
                    },
                    onDelete: {
                        apiKeyManager.removeKey(provider: key.provider, name: key.name)
                    }
                )
            }

            if apiKeyManager.keys.isEmpty {
                Text("No API keys configured. Add one to get started.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }

            // Add new key form
            if showAddKey {
                addKeyForm
            }
        }
    }

    private var addKeyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Add API Key").font(.subheadline).fontWeight(.medium)

            // Provider — quick picks + free text
            HStack(spacing: 8) {
                Text("Provider")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
                TextField("e.g. openrouter, openai, together, deepseek...", text: $newKeyProvider)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Quick provider buttons
            HStack(spacing: 4) {
                Text("")
                    .frame(width: 60)
                ForEach(Self.knownProviders, id: \.name) { p in
                    Button(p.name) {
                        newKeyProvider = p.name
                        newKeyBaseUrl = p.baseUrl ?? ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(newKeyProvider == p.name ? .accentColor : .secondary)
                }
            }

            HStack(spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
                TextField("e.g. Personal, Work (optional)", text: $newKeyName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Text("API Key")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
                SecureField("sk-...", text: $newKeyValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 8) {
                Text("Base URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
                TextField("e.g. https://openrouter.ai/api/v1", text: $newKeyBaseUrl)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            if !newKeyBaseUrl.isEmpty {
                HStack {
                    Text("")
                        .frame(width: 60)
                    Text("Custom base URL set — model requests will go to this endpoint")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddKey = false
                    clearAddForm()
                }
                .controlSize(.small)

                Button("Add Key") {
                    let key = APIKeyManager.ProviderKey(
                        provider: newKeyProvider.isEmpty ? "custom" : newKeyProvider,
                        name: newKeyName.isEmpty ? "default" : newKeyName,
                        apiKey: newKeyValue,
                        baseUrl: newKeyBaseUrl.isEmpty ? nil : newKeyBaseUrl,
                        isSelected: true
                    )
                    apiKeyManager.setKey(key)
                    showAddKey = false
                    clearAddForm()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newKeyValue.isEmpty)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func clearAddForm() {
        newKeyProvider = ""
        newKeyName = ""
        newKeyValue = ""
        newKeyBaseUrl = ""
    }

    /// Sync @State fields from session model (called once on appear)
    private func syncFromSession() {
        let m = session.model
        customModelId = m.id
        customModelApi = m.api
        customContextWindow = "\(m.contextWindow)"
        customMaxTokens = "\(m.maxTokens)"
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Settings", systemImage: "gear")
                .font(.headline)

            Toggle("Auto-compaction", isOn: Binding(
                get: { session.settingsManager.isCompactionEnabled },
                set: { session.settingsManager.setCompactionEnabled($0) }
            ))

            Toggle("Auto-retry on error", isOn: Binding(
                get: { session.settingsManager.isRetryEnabled },
                set: { session.settingsManager.setRetryEnabled($0) }
            ))

            HStack {
                Text("Working directory:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(session.cwd)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - API Key Row

struct APIKeyRow: View {
    let key: APIKeyManager.ProviderKey
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .green : .secondary)
                .onTapGesture { onSelect() }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(key.provider)
                        .font(.caption)
                        .fontWeight(.medium)
                    if key.name != "default" {
                        Text("(\(key.name))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                if let url = key.baseUrl, !url.isEmpty {
                    Text(url)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(maskKey(key.apiKey))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(isSelected ? Color.green.opacity(0.05) : Color.clear)
        .cornerRadius(6)
    }

    private func maskKey(_ key: String) -> String {
        if key.count <= 8 { return "****" }
        return String(key.prefix(4)) + "..." + String(key.suffix(4))
    }
}

// MARK: - Info Chip

struct InfoChip: View {
    let label: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}
