import SwiftUI

/// Ask about this meeting — the island's Q&A pane.
///
/// Same language as the rest of the island: pure black card, 12pt text, 10pt
/// semibold caps labels, 24pt icon controls, press-scale feedback. The pane
/// answers from the transcript once there is one — and from the app itself
/// before that (see AskAssistant.swift). Transcript answers carry the
/// verbatim quotes they rest on, each with its time in the meeting.
@MainActor
final class AskViewModel: ObservableObject {
    @Published var suggestions: [String] = []
    @Published var isLoadingSuggestions = false
    /// Whether the loaded suggestion list is currently shown under the
    /// button. The button itself is always visible; this toggles the list.
    @Published var showSuggestions = false
    @Published var currentQuestion: String?
    @Published var answer: AskAnswer?
    @Published var isAsking = false
    @Published var errorMessage: String?
    @Published var input = ""
    /// Which part of the meeting the answers draw on (live partial, long
    /// meeting). Set from the manager after each Ask call; nil when the whole
    /// transcript fits.
    @Published var coverageNote: String?

    weak var manager: MeetingManager?

    func bind(_ manager: MeetingManager) { self.manager = manager }

    var hasAnswer: Bool { answer != nil }

    /// Suggested questions for the meeting so far. Kept once loaded; the
    /// transcript only grows, so stale suggestions stay usable.
    func loadSuggestions() async {
        guard let manager, suggestions.isEmpty, !isLoadingSuggestions else { return }
        isLoadingSuggestions = true
        errorMessage = nil
        do {
            suggestions = try await manager.suggestedQuestions()
            coverageNote = manager.askCoverageNote
            showSuggestions = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingSuggestions = false
    }

    /// The button's action: load the list the first time, then toggle it.
    /// The button stays visible even after an answer, so the user can
    /// always pull the list back up.
    func toggleSuggestions() async {
        guard !isLoadingSuggestions else { return }
        if !suggestions.isEmpty {
            showSuggestions.toggle()
            return
        }
        await loadSuggestions()
    }

    /// Asks one question; a follow-up just replaces the displayed answer.
    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking, let manager else { return }
        isAsking = true
        errorMessage = nil
        currentQuestion = trimmed
        answer = nil
        input = ""
        // The answer takes the room; the button stays, and the list can be
        // pulled back up with it.
        showSuggestions = false
        do {
            answer = try await manager.ask(question: trimmed)
            coverageNote = manager.askCoverageNote
        } catch {
            errorMessage = error.localizedDescription
        }
        isAsking = false
    }
}

struct AskPane: View {
    @ObservedObject var viewModel: AskViewModel
    @ObservedObject var manager: MeetingManager
    var reveal: Bool
    var width: CGFloat
    var bottomBar: AnyView

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .modifier(NotchIslandView.StaggerReveal(index: 0, active: reveal))

            // Compact "What should I ask?" — pinned under the header so it
            // is always visible, even after an answer. The list below it
            // toggles; the answer keeps its room underneath.
            suggestionsButton
                .modifier(NotchIslandView.StaggerReveal(index: 1, active: reveal))
                .padding(.top, 6)
                .padding(.horizontal, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.showSuggestions {
                        suggestionRows
                    }
                    if viewModel.isAsking {
                        askingRow
                    } else if let answer = viewModel.answer {
                        answerView(answer)
                    } else if !viewModel.showSuggestions && !viewModel.isLoadingSuggestions && manager.canAsk {
                        Text("Ask anything about what's been said so far — decisions, commitments, open items.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .padding(.top, 2)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
            }
            .modifier(NotchIslandView.StaggerReveal(index: 2, active: reveal))

            inputRow
                .modifier(NotchIslandView.StaggerReveal(index: 3, active: reveal))
                .padding(.top, 8)

            Spacer(minLength: 6)
            bottomBar
                .modifier(NotchIslandView.StaggerReveal(index: 4, active: reveal))
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(width: width, height: IslandMetrics.maxBodyHeight, alignment: .top)
        .onAppear {
            viewModel.bind(manager)
            // Focus after the panel has had a moment to become key (see the
            // askOpen onChange): typing works straight away, and tapping the
            // field focuses it anyway.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                inputFocused = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // No back button here: the main chevron (top right) is the way
            // back — Ask → the page it came from, then collapse.
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.blue.opacity(0.9))
                Text("Ask about this meeting")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(height: 24)
            Text("Answers come from the transcript — or the app, before it's ready.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
            if let note = viewModel.coverageNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Suggestions — compact button, always visible; list toggles

    private var suggestionsButton: some View {
        Button {
            Task { await viewModel.toggleSuggestions() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.blue.opacity(0.9))
                Text("What should I ask?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
                if viewModel.isLoadingSuggestions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: viewModel.showSuggestions ? "chevron.up" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(viewModel.isLoadingSuggestions)
    }

    private var suggestionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.suggestions, id: \.self) { suggestion in
                Button {
                    Task { await viewModel.ask(suggestion) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.blue.opacity(0.7))
                            .padding(.top, 2)
                        Text(suggestion)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    // MARK: Asking / answer

    private var askingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerView(_ answer: AskAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = viewModel.currentQuestion {
                Text(question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            Text(answer.answer)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineSpacing(2)
            if !answer.sources.isEmpty {
                Text("SOURCES (\(answer.sources.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.top, 4)
                ForEach(answer.sources) { source in
                    HStack(alignment: .top, spacing: 8) {
                        if source.time >= 0 {
                            Text(source.timeLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text(source.quote)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(viewModel.hasAnswer ? "Ask another question…"
                        : (manager.canAsk ? "Ask a question…" : "Ask about the meeting or the app…"),
                      text: $viewModel.input)
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { Task { await viewModel.ask(viewModel.input) } }
                .disabled(viewModel.isAsking)
            Button {
                Task { await viewModel.ask(viewModel.input) }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || viewModel.isAsking)
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(inputFocused ? 0.35 : 0.12), lineWidth: 1))
        .padding(.horizontal, 8)
    }
}
