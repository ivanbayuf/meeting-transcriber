import SwiftUI
import AppKit

/// Hosted in SettingsWindowController's NSWindow (not a SwiftUI Settings scene).
struct SettingsView: View {
    static let width: CGFloat = 460
    static let height: CGFloat = 600

    @EnvironmentObject var manager: MeetingManager
    @State private var isTestingGroq = false

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { scroll(proxy, to: manager.settingsFocus) }
                .onChange(of: manager.settingsFocus) { _, section in scroll(proxy, to: section) }
        }
        .frame(width: Self.width, height: Self.height)
    }

    private var form: some View {
        Form {
            Section("Groq API") {
                SecureField("API Key", text: $manager.groqAPIKey)
                HStack {
                    Button(isTestingGroq ? "Testing…" : "Test") {
                        Task {
                            isTestingGroq = true
                            _ = await manager.verifyGroqKey()
                            isTestingGroq = false
                        }
                    }
                    .disabled(isTestingGroq || manager.groqAPIKey.isEmpty)

                    switch manager.groqKeyState {
                    case .idle:
                        EmptyView()
                    case .valid:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .error(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DisclosureGroup("Advanced") {
                    Picker("Transcription Model", selection: $manager.transcriptionModel) {
                        ForEach(AppSettings.availableTranscriptionModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Picker("Summary Model", selection: $manager.summaryModel) {
                        ForEach(AppSettings.availableSummaryModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Picker("Fallback Summary Model", selection: $manager.fallbackSummaryModel) {
                        ForEach(AppSettings.availableSummaryModels + ["openai/gpt-oss-20b"], id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }

            Section {
                ForEach(OutputDestination.allCases) { destination in
                    SettingsDestinationRow(destination: destination)
                }
            } header: {
                Text("Send notes to")
            } footer: {
                Text("Notes go to one place: purpose, key points, decisions, action items, and open questions & risks. Markdown and clipboard also include the full transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id(SettingsSection.outputs)

            Section("Island") {
                Toggle("Show island on launch", isOn: $manager.autoShowIsland)
            }

            Section("Recording") {
                Toggle("Auto-delete audio once notes are saved", isOn: $manager.autoDeleteAudio)
                    .help("Deletes the recording after Notion or the Markdown file succeeds. Clipboard alone doesn't count.")

                Picker("Transcription Language", selection: $manager.selectedLanguageRaw) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
            }

            Section("Advanced") {
                Button("Clear Meeting History", role: .destructive) {
                    manager.meetingHistory.removeAll()
                    manager.saveHistory()
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Deep link from the island ("Connect Notion…"). Deferred a beat so the
    /// Form has laid out its rows before scrolling; then the focus is consumed.
    private func scroll(_ proxy: ScrollViewProxy, to section: SettingsSection?) {
        guard let section else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.25)) {
                if section == .notion {
                    proxy.scrollTo(SettingsSection.notion.rawValue, anchor: .top)
                } else {
                    proxy.scrollTo(section, anchor: .top)
                }
            }
            manager.settingsFocus = nil
        }
    }

}

/// One radio row in Settings → "Send notes to". Setup first: a destination
/// that isn't set up shows its setup action instead of being selectable.
private struct SettingsDestinationRow: View {
    @EnvironmentObject var manager: MeetingManager
    @State private var showingNotionConnect = false
    let destination: OutputDestination

    private var isReady: Bool { manager.isReady(destination) }
    private var isSelected: Bool { manager.activeDestination == destination }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if destination == .notion && !manager.notionConnected {
                    showingNotionConnect = true
                } else {
                    manager.select(destination)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14))
                    Image(systemName: destination.systemImage)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(destination.title)
                        if let caption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isReady && destination != .notion)
            .opacity(isReady || destination == .notion ? 1 : 0.5)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            trailingAction
        }
        .id(destination == .notion ? SettingsSection.notion.rawValue : destination.rawValue)
        .onAppear {
            if manager.settingsFocus == .notion { showingNotionConnect = true }
        }
        .onChange(of: manager.settingsFocus) { _, section in
            if section == .notion { showingNotionConnect = true }
        }
        .onChange(of: manager.notionConnected) { _, connected in
            if connected { showingNotionConnect = false }
        }
        if destination == .notion && showingNotionConnect && !manager.notionConnected {
            NotionConnectView()
                .padding(.leading, 28)
                .padding(.top, 4)
        }
    }

    private var caption: String? {
        switch destination {
        case .notion: return isReady ? "Connected — Meetings database" : nil
        case .googleDocs: return isReady ? "Connected — Drive folder “Meeting Notes”" : nil
        case .markdown: return isReady ? "Folder: \(manager.markdownFolderName)" : nil
        case .clipboard: return nil
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch destination {
        case .notion where isReady:
            Button("Disconnect", role: .destructive) { manager.disconnectNotion() }
                .controlSize(.small)
        case .notion where !isReady:
            Button { showingNotionConnect = true } label: {
                Text("Connect Notion")
                    .fixedSize(horizontal: true, vertical: false)
            }
                .controlSize(.small)
        case .googleDocs where isReady:
            Button("Disconnect", role: .destructive) { manager.disconnectGoogle() }
                .controlSize(.small)
        case .googleDocs:
            Button { manager.connectGoogle() } label: {
                Text(manager.googleConnecting ? "Waiting for browser…" : "Connect Google")
                    .fixedSize(horizontal: true, vertical: false)
            }
                .controlSize(.small)
                .disabled(manager.googleConnecting)
        case .markdown:
            Button { manager.chooseMarkdownFolder() } label: {
                Text(isReady ? "Directory" : "Choose directory")
                    .fixedSize(horizontal: true, vertical: false)
            }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }
}
