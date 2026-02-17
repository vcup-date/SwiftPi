import SwiftUI
import AppKit
import PiCodingAgent

// MARK: - Skill Browser

public struct SkillBrowser: View {
    @ObservedObject var session: AgentSession
    @State private var showCreateSkill = false
    @State private var newSkillDescription = ""
    @State private var createInProject = false
    @State private var useDirectory = false
    @State private var isCreating = false
    @State private var reloadRotation: Double = 0
    @State private var showReloadFlash = false

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with actions
            HStack {
                Label("Skills", systemImage: "star")
                    .font(.headline)
                Spacer()
                Text(showReloadFlash ? "Reloaded!" : "\(session.skills.count) loaded")
                    .font(.caption)
                    .foregroundColor(showReloadFlash ? .green : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: showReloadFlash)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        reloadRotation += 360
                    }
                    session.reloadSkills()
                    showReloadFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showReloadFlash = false
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .rotationEffect(.degrees(reloadRotation))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Reload skills")

                Button(action: { openSkillsFolder() }) {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open skills folder")

                Button(action: { showCreateSkill.toggle() }) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Create new skill with AI")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Create skill panel
            if showCreateSkill {
                createSkillPanel
                Divider()
            }

            // Skills list
            if session.skills.isEmpty && !showCreateSkill {
                VStack(spacing: 12) {
                    Image(systemName: "star.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No skills loaded")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Add .md files, .swift files, or skill-name/SKILL.md\ndirectories to ~/.swiftpi/skills/ or .swiftpi/skills/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button("Open Skills Folder") { openSkillsFolder() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Create with AI") { showCreateSkill = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(session.skills) { skill in
                        SkillRow(skill: skill)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Prompt templates
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Prompt Templates", systemImage: "doc.text")
                        .font(.headline)
                    Spacer()
                    Text("\(session.promptTemplates.count) loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if session.promptTemplates.isEmpty {
                    Text("No templates. Add .md files to ~/.swiftpi/prompts/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                } else {
                    List {
                        ForEach(session.promptTemplates) { template in
                            PromptTemplateRow(template: template)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    // MARK: - Create Skill Panel

    private var createSkillPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Create Skill", systemImage: "wand.and.stars")
                    .font(.caption)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { showCreateSkill = false }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }

            Text("Describe what the skill should do. The AI will create a skill following Claude's Agent Skills standard.")
                .font(.caption2)
                .foregroundColor(.secondary)

            TextEditor(text: $newSkillDescription)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(.separatorColor), lineWidth: 0.5)
                )

            HStack(spacing: 16) {
                Picker("Location:", selection: $createInProject) {
                    Text("User (~/.swiftpi/skills/)").tag(false)
                    Text("Project (.swiftpi/skills/)").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                Picker("Format:", selection: $useDirectory) {
                    Text("Single file").tag(false)
                    Text("Directory").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .help("Directory: skill-name/SKILL.md + resources. Single: skill-name.md")

                Spacer()

                if isCreating {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Creating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button(action: createSkill) {
                        Label("Create", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Actions

    private func openSkillsFolder() {
        let userDir = userSkillsDirectory()
        // Create if it doesn't exist
        try? FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: userDir))
    }

    private func createSkill() {
        let desc = newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { return }

        isCreating = true
        Task {
            await session.createSkill(description: desc, inProject: createInProject, useDirectory: useDirectory)
            isCreating = false
            newSkillDescription = ""
            showCreateSkill = false
        }
    }
}

// MARK: - Skill Row

struct SkillRow: View {
    let skill: Skill
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: skillIcon)
                    .font(.caption)
                    .foregroundColor(skillIconColor)
                Text(skill.name)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(skill.source.rawValue)
                    .font(.caption2)
                    .foregroundColor(skill.source == .builtin ? .white : nil)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(skill.source == .builtin ? Color.blue.opacity(0.7) : Color.secondary.opacity(0.15))
                    .cornerRadius(3)

                if skill.isDirectorySkill {
                    Text("dir")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(3)
                }

                if skill.isSwiftScript {
                    Text("swift")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(3)
                }

                if skill.disableModelInvocation {
                    Text("hidden")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                Spacer()

                // Open in Finder
                Button(action: {
                    if skill.isDirectorySkill {
                        NSWorkspace.shared.open(URL(fileURLWithPath: skill.baseDir))
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.filePath)])
                    }
                }) {
                    Image(systemName: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }

            Text(skill.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(expanded ? nil : 2)

            if expanded {
                Text(skill.filePath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)

                // Show resource files for directory skills
                if skill.isDirectorySkill && !skill.resourceFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resources:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fontWeight(.medium)
                        ForEach(skill.resourceFiles, id: \.self) { file in
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Text(file)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(6)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                }

                Text(skill.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 4)
    }

    private var skillIcon: String {
        if skill.isSwiftScript { return "swift" }
        if skill.isDirectorySkill { return "folder.fill" }
        return "star.fill"
    }

    private var skillIconColor: Color {
        if skill.isSwiftScript { return .orange }
        if skill.isDirectorySkill { return .purple }
        return .yellow
    }
}

// MARK: - Prompt Template Row

struct PromptTemplateRow: View {
    let template: PromptTemplate
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text("/\(template.name)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)

                Text(template.source)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)

                Spacer()

                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }

            if !template.description.isEmpty {
                Text(template.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if expanded {
                Text(template.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 4)
    }
}
