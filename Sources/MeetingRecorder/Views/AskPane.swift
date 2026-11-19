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
    /// The conversation so far, oldest first; the pane shows it as chat bubbles.
    @Published var turns: [AskTurn] = []
    @Published var isAsking = false
    @Published var errorMessage: String?
    @Published var input = ""
    /// Which part of the meeting the answers draw on (live partial, long
    /// meeting). Set from the manager after each Ask call; nil when the whole
    /// transcript fits.
    @Published var coverageNote: String?

    weak var manager: MeetingManager?

    func bind(_ manager: MeetingManager) { self.manager = manager }

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

    /// Asks one question and appends it to the conversation; earlier
    /// questions and answers stay above it.
    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking, let manager else { return }
        isAsking = true
        errorMessage = nil
        input = ""
        withAnimation(IslandMotion.tabSwap) { turns.append(AskTurn(question: trimmed)) }
        let index = turns.count - 1
        do {
            turns[index].answer = try await manager.ask(question: trimmed)
            coverageNote = manager.askCoverageNote
        } catch {
            turns[index].error = error.localizedDescription
        }
        isAsking = false
    }
}

/// One question and its reply (nil while waiting).
struct AskTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: AskAnswer?
    var error: String?
}

struct AskPane: View {
    @ObservedObject var viewModel: AskViewModel
    @ObservedObject var manager: MeetingManager
    var reveal: Bool
    var width: CGFloat

    @FocusState private var inputFocused: Bool
    @State private var showSuggestions = false
    @State private var hoveredSuggestion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .modifier(NotchIslandView.StaggerReveal(index: 0, active: reveal))
                // The suggestion list hangs over the chat, so it must draw on top.
                .zIndex(1)


            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.red.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
                // Follow the conversation: new question, then its answer.
                .onChange(of: viewModel.turns.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: viewModel.isAsking) { _, _ in scrollToEnd(proxy) }
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .overlay {
                if viewModel.turns.isEmpty && viewModel.errorMessage == nil {
                    Text("No question yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
            // Soft fade at the edges so a long answer reads as scrollable.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            })
            .modifier(NotchIslandView.StaggerReveal(index: 2, active: reveal))

            // The form is always on, under the dropdown.
            inputRow
                .modifier(NotchIslandView.StaggerReveal(index: 3, active: reveal))
                .padding(.top, 8)
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

    /// One line: what answers are based on, and the Suggestions dropdown.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Answers come from the transcript.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            suggestionsDropdown
                .overlay(alignment: .topTrailing) {
                    if showSuggestions { suggestionList.frame(width: 260).offset(y: 32) }
                }
        }
        .padding(.top, 2)
        .padding(.horizontal, 8)
    }

    // MARK: Suggestions dropdown

    /// The "What should I ask?" trigger: a row with a chevron that drops the
    /// island's own suggestion list over the answer (no native menu chrome).
    private var suggestionsDropdown: some View {
        Button {
            withAnimation(IslandMotion.contentIn) { showSuggestions.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("Suggestions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                if viewModel.isLoadingSuggestions {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .rotationEffect(.degrees(showSuggestions ? 180 : 0))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(showSuggestions ? 0.12 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingSuggestions)
        .accessibilityLabel("Suggestions")
        .accessibilityHint(showSuggestions ? "Hides suggested questions" : "Shows suggested questions")
    }

    /// Suggested questions, one per row; picking one asks it and closes the list.
    private var suggestionList: some View {
        // Six generic questions are taller than the room under the trigger: scroll.
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.suggestions.isEmpty {
                Text("No suggestions right now")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            } else {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button {
                        withAnimation(IslandMotion.contentOut) { showSuggestions = false }
                        Task { await viewModel.ask(suggestion) }
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(hoveredSuggestion == suggestion ? 0.1 : 0),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredSuggestion = $0 ? suggestion : nil }
                }
            }
        }
        .padding(4)
        }
        .frame(maxHeight: 132)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .transition(.opacity.combined(with: .offset(y: -4)))
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

    private static let bottomID = "ask-bottom"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(IslandMotion.tabSwap) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    /// Your question on the right, the reply on the left.
    private func turnView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.question)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.04, green: 0.47, blue: 1.0), in: BubbleShape(mine: true))
            }
            HStack {
                Group {
                    if let answer = turn.answer {
                        answerView(answer)
                    } else if let error = turn.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.85))
                    } else {
                        askingRow
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.07), in: BubbleShape(mine: false))
                Spacer(minLength: 24)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private func answerView(_ answer: AskAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.answer)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineSpacing(2)
                .textSelection(.enabled)
            if !answer.sources.isEmpty {
                Text("SOURCES (\(answer.sources.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.top, 2)
                ForEach(answer.sources) { source in
                    HStack(alignment: .top, spacing: 8) {
                        if source.time >= 0 {
                            Text(source.timeLabel)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
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

/// Chat bubble: rounded, with the corner nearest the speaker tightened.
private struct BubbleShape: Shape {
    var mine: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 12, tight: CGFloat = 4
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: r,
            bottomLeading: mine ? r : tight,
            bottomTrailing: mine ? tight : r,
            topTrailing: r))
    }
}
