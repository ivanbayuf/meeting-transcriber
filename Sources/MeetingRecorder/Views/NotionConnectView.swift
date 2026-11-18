import SwiftUI
import AppKit

struct NotionConnectView: View {
    @EnvironmentObject var manager: MeetingManager
    @State private var secret = ""
    @State private var pageLink = ""
    @State private var showingTutorial = false

    private let integrationURL = URL(string: "https://www.notion.so/profile/integrations/internal")!
    private var isConnecting: Bool { manager.notionConnectState == .connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                } else if manager.notionConnected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("✓ Connected — Meetings database")
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.medium))

            if manager.notionConnected {
                HStack {
                    Text(masked(manager.notionToken))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        secret = ""
                        pageLink = ""
                        manager.disconnectNotion()
                    }
                    .controlSize(.small)
                }
            } else {
                SecureField("Integration secret", text: $secret, prompt: Text("ntn_… or secret_…"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isConnecting)
                TextField("Meeting Transcription page link", text: $pageLink,
                          prompt: Text("Paste the Notion page link or 32-character ID"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isConnecting)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(integrationURL)
                    } label: {
                        Text("Create an integration")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: connect) {
                        HStack(spacing: 6) {
                            if isConnecting { ProgressView().controlSize(.small) }
                            Text(isConnecting ? "Connecting…" : "Connect & Set Up")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pageLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let error = manager.notionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("How do I connect?", isExpanded: $showingTutorial) {
                    VStack(alignment: .leading, spacing: 6) {
                        tutorialStep(1, "Settings & members → Connections → New (“Meeting Transcriber”)")
                        tutorialStep(2, "Enable Read, Update, and Insert capabilities")
                        tutorialStep(3, "Copy the integration secret")
                        tutorialStep(4, "Open the “Meeting Transcription” page → ⋯ → Connections → tick the integration")
                        tutorialStep(5, "On that page, ⋯ → Copy link")
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if secret.isEmpty, manager.notionConnected { secret = manager.notionToken }
        }
    }

    private func tutorialStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .fontWeight(.semibold)
                .frame(width: 16, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    private func connect() {
        Task { await manager.connectNotion(secret: secret, pageLink: pageLink) }
    }

    private func masked(_ value: String) -> String {
        guard value.count >= 12 else { return String(repeating: "•", count: value.count) }
        return String(value.prefix(6)) + String(repeating: "•", count: 8) + String(value.suffix(4))
    }
}
