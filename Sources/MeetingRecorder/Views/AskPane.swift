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
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingSuggestions = false
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

            // "What should I ask?" is a dropdown: the trigger row, and the
            // suggestions pop out as a native menu (no chips, no list
            // taking up pane space). Picking one asks it straight away.
            suggestionsDropdown
                .modifier(NotchIslandView.StaggerReveal(index: 1, active: reveal))
                .padding(.top, 6)
                .padding(.horizontal, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.isAsking {
                        askingRow
                    } else if let answer = viewModel.answer {
                        answerView(answer)
                    } else if manager.canAsk {
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

            // The form is always on, under the dropdown.
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
            if viewModel.suggestions.isEmpty {
                Task { await viewModel.loadSuggestions() }
            }
            focusInput()
        }
    }

    private func focusInput() {
        // Focus after the panel has had a moment to become key (see the
        // askOpen onChange): typing works straight away, and tapping the
        // field focuses it anyway.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // No title here: the Ask tab in the navigation already says
            // what this pane is. Just the basis line (and the coverage
            // note, once a question has been asked).
            Text("Answers come from the transcript, or the app.")
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

    // MARK: Suggestions dropdown

    /// The "What should I ask?" trigger: a row with a chevron; the
    /// suggestions pop out as a native menu. Text only, no star — the blue
    /// star lives exactly once, on the Ask tab in the main navigation.
    private var suggestionsDropdown: some View {
        Menu {
            if viewModel.suggestions.isEmpty {
                Button("No suggestions right now") {}
                    .disabled(true)
            } else {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        Task { await viewModel.ask(suggestion) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("What should I ask?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
                if viewModel.isLoadingSuggestions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.down")
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
        .menuStyle(.borderlessButton)
        .disabled(viewModel.isLoadingSuggestions)
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
            TextField("Ask about the meeting…", text: $viewModel.input)
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
