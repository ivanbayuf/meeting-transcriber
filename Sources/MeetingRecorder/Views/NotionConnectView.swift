import SwiftUI
import AppKit

// MARK: - Notion Connect — ONE secret field + ONE "Connect & Set Up" button
// Verifies the secret (GET /users/me), then finds-or-creates the
// "Meeting Transcription" project + "Meetings" database (NotionClient+Setup).
// All state lives in MeetingManager.shared; this view only holds the draft text.

struct NotionConnectView: View {
    @EnvironmentObject var manager: MeetingManager
    /// Draft secret; prefilled with the remembered one.
    @State private var secret: String = ""

    private var isConnecting: Bool { manager.notionConnectState == .connecting }

    private var errorText: String? {
        if case .failed(let message) = manager.notionConnectState { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            if manager.notionConfigured && !isConnecting {
                connectedRow
            } else {
                connectForm
            }
        }
        .padding(.vertical, 2)
        .onAppear { if secret.isEmpty { secret = manager.notionToken } }
    }

    // MARK: Status line

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if isConnecting {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            } else if manager.notionConfigured {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Text("Not connected")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium))
    }

    // MARK: Not connected / failed

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Integration secret", text: $secret, prompt: Text("ntn_…"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(isConnecting)
                .onSubmit(connect)

            Button(action: connect) {
                Text(isConnecting ? "Connecting…" : "Connect & Set Up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 4) {
                    Text("Creates a “Meeting Transcription” page with a “Meetings” database. Need a secret?")
                    Link("Create an integration", destination: URL(string: "https://www.notion.so/profile/integrations/internal")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Connected

    private var connectedRow: some View {
        HStack(spacing: 8) {
            Text(masked(manager.notionToken))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Disconnect") {
                secret = ""
                manager.disconnectNotion()
            }
            .controlSize(.small)
        }
    }

    // MARK: Actions

    private func connect() {
        let value = secret
        Task { await manager.connectNotion(secret: value) }
    }

    private func masked(_ s: String) -> String {
        if s.count < 12 { return String(repeating: "•", count: s.count) }
        return String(s.prefix(6)) + String(repeating: "•", count: 8) + String(s.suffix(4))
    }
}
