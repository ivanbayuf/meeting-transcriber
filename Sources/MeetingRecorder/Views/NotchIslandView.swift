// ORCHESTRATOR-GLUE: needs manager.verifyGroqKey() async -> Bool, manager.groqKeyState: GroqKeyState (enum idle/valid/error(String)), manager.audioRecorder.micLevel: Float, manager.audioRecorder.totalFrames: Int, manager.micPermissionNeeded: Bool
import SwiftUI
import AppKit
import Combine

// MARK: - Geometry

/// Every size the island uses, derived once per screen. Hard-coded per state
/// rather than measured: the set of states is small and fixed, and fixed heights
/// let the spring animate between known values with no layout feedback loop.
struct IslandMetrics: Equatable {
    /// Width of the camera housing; 0 on screens without a notch.
    var notchWidth: CGFloat
    /// Collapsed pill height = notch height on notched screens, else 36.
    var topBarHeight: CGFloat

    /// Transparent margin around the card so its shadow (radius 18, y 10) and
    /// the morph spring's small overshoot aren't clipped by the panel edge.
    static let shadowInset: CGFloat = 32
    /// Tallest body below the top row (outputs/history pages).
    /// Item 43: 192 (was 184). Recording-state outputs content is
    /// 4 + 16 + 4 + (32 + 40 + 32 + 2×4) + 6 + 30 + 12 = 184 — zero slack, so
    /// any text-metric rounding ate the 12pt bottom inset. +8 leaves the
    /// Spacer room and keeps the bottom bar pinned exactly 12pt from the edge.
    static let maxBodyHeight: CGFloat = 228 // 192 + one 36pt destination row (Google Docs)
    /// Expanded card width. Widened to 330 (item 27) so the "Send notes" section
    /// has room. Still clears "Window"/"Help" menus on a 14" display. Tune here.
    static let baseExpandedWidth: CGFloat = 330
    /// Collapsed = icon-only. Each wing holds one 24pt control (record left,
    /// chevron right) → 80pt total without a notch. On a notched screen the
    /// wings sit either side of the camera housing (nothing can draw under it).
    static let idleWing: CGFloat = 40
    /// While recording the wings widen just enough for the live timer.
    /// Fits the timer box: inset 4 + 7 + dot 6 + 5 + "00:00" ≈36 + 7 ≈ 65.
    static let recordingWing: CGFloat = 66
    static let collapsedBottomRadius: CGFloat = 12
    /// Expanded: square top corners (flush with the screen edge, like the
    /// notch), rounded bottom.
    static let expandedBottomRadius: CGFloat = 20
    static let horizontalPadding: CGFloat = 12
    /// Radius of the concave "ears" that flare the top corners into the screen edge.
    static let earRadius: CGFloat = 8

    /// Top-row controls are 24pt boxes. The gap from a box to the island's side
    /// equals the gap above/below it, so left, right, top and bottom all match.
    static let controlSize: CGFloat = 24
    /// Space between a glyph and the edge of its (highlightable) box.
    static let controlContentInset: CGFloat = 7
    var controlEdgeInset: CGFloat { max(4, (topBarHeight - Self.controlSize) / 2) }
    /// Concentric with the collapsed island corner: outer radius minus the gap.
    var controlCornerRadius: CGFloat { max(4, Self.collapsedBottomRadius - controlEdgeInset) }

    var hasNotch: Bool { notchWidth > 0 }
    func collapsedWidth(recording: Bool) -> CGFloat {
        notchWidth + 2 * (recording ? Self.recordingWing : Self.idleWing)
    }
    /// Never narrower than the widest pill, so on a notch the card only grows downward.
    var expandedWidth: CGFloat { max(Self.baseExpandedWidth, collapsedWidth(recording: true)) }
    var panelSize: CGSize {
        CGSize(width: expandedWidth + 2 * Self.shadowInset,
               height: topBarHeight + Self.maxBodyHeight + Self.shadowInset)
    }

    init(notchWidth: CGFloat = 0, topBarHeight: CGFloat = 36) {
        self.notchWidth = notchWidth
        self.topBarHeight = topBarHeight
    }

    @MainActor
    init(screen: NSScreen?) {
        guard let screen,
              screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            self.init()
            return
        }
        self.init(notchWidth: max(0, screen.frame.width - left.width - right.width),
                  topBarHeight: max(32, screen.safeAreaInsets.top))
    }
}

/// Rect with independently animatable top/bottom corner radii. The island keeps
/// top corners square in both states (flush with the screen edge); only the
/// bottom radius changes. Radii are clamped, so spring overshoot is harmless.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let t = max(0, min(topRadius, limit))
        let b = max(0, min(bottomRadius, limit))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY + t), radius: t)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX + t, y: rect.minY), radius: t)
        p.closeSubpath()
        return p
    }
}

/// Concave fillet that flares the island's top-left corner into the screen edge,
/// like the hardware notch. Drawn in an r×r box to the LEFT of the card; mirror
/// with scaleEffect(x: -1) for the right side. The arc is tangent to the top
/// edge and the card's side, so it is a true quarter circle centred at (0, r).
struct IslandEar: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: rect.width)
        p.closeSubpath()
        return p
    }
}

// MARK: - Motion tokens

enum IslandMotion {
    /// Enter (expand): spring WITH bounce — Ivan's final call: 0.3s, 0.3 bounce
    /// (Emil's top of his 0.1–0.3 band). DEBUG: `defaults write
    /// com.ivanbayu.meetingrecorder debugSpringDuration 0.3` / `debugSpringBounce 0.3`
    /// (seconds / 0–1, read live, no rebuild).
    static var expand: Animation {
        let d = UserDefaults.standard.object(forKey: "debugSpringDuration") as? Double ?? 0.3
        let b = UserDefaults.standard.object(forKey: "debugSpringBounce") as? Double ?? 0.3
        return .spring(duration: d, bounce: b)
    }
    /// Exit (collapse): same family, quicker — 0.25s, a touch less bounce.
    /// DEBUG: `debugCollapseDuration 0.25` / `debugCollapseBounce 0.15`.
    static var collapse: Animation {
        let d = UserDefaults.standard.object(forKey: "debugCollapseDuration") as? Double ?? 0.25
        let b = UserDefaults.standard.object(forKey: "debugCollapseBounce") as? Double ?? 0.15
        return .spring(duration: d, bounce: b)
    }
    /// Record button mic ↔ stop swap: a binary state change, so a short
    /// scale+opacity crossfade on a slightly faster spring (~0.2s) with a
    /// small overshoot — re-taps feel instant.
    static let glyphSwap = Animation.spring(response: 0.2, dampingFraction: 0.7)
    /// Inner content crossfade — strong ease-out, cubic-bezier(0.23, 1, 0.32, 1).
    static let contentIn = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    /// Exits are shorter than entrances: the user already decided to leave.
    static let contentOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.10)
    /// Body waits for the card to be ~⅓ open so text never spills past the edge.
    static let contentInDelay: Double = 0.05
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.10)
    /// Reduce Motion fallback: opacity only, no spring.
    static let reducedFade = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    /// The only continuous animation in the app — record button pulse.
    static let pulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    /// Blinking dot: ~1s steady cadence with autoreversal (item 24).
    static let blink = Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
}

/// Height driven by the morph spring. The overshoot on collapse would
/// otherwise briefly ask for a negative frame height.
struct ClampedHeight: ViewModifier, Animatable {
    var height: CGFloat

    // nonisolated: Animatable's requirement is nonisolated while ViewModifier
    // conformance infers @MainActor on the type. CGFloat storage is Sendable.
    nonisolated var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: max(0, height), alignment: .top)
    }
}

/// Pointer affordance for the black island, using a compositor transform.
/// `enabled: false` (disabled target) suppresses the scale so a dead control
/// doesn't advertise itself. Hover is reset on disappear: a view removed from
/// under the pointer never receives onHover(false), which would otherwise
/// leave it stuck at 1.06 the next time it appears.
struct ElementHoverScale: ViewModifier {
    @Binding var isHovering: Bool
    var enabled: Bool = true
    var cornerRadius: CGFloat = 8
    /// Off for wide controls: 1.1× on a ~65pt box grows ~3pt per side and eats the 4pt edge gap.
    var scales: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let lit = isHovering && enabled
        content
            // The highlight IS the control's box (glyph centred, 7pt each side), so it
            // is always centred on the glyph. Scale alone was too subtle.
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(lit ? 0.14 : 0))
            )
            .scaleEffect(lit && scales && !reduceMotion ? 1.1 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3), value: lit)
            .onHover { isHovering = $0 }
            .onDisappear { isHovering = false }
    }
}

// MARK: - State

/// UI-only island state: expansion, page, hover timing, the success flash.
/// Recording/processing state stays in MeetingManager; the view derives the rest.
@MainActor
final class IslandModel: ObservableObject {
    enum Page { case main, history }

    @Published var metrics: IslandMetrics
    @Published private(set) var isExpanded = false
    @Published var page: Page = .main
    /// Non-nil while the "Saved" result card is showing.
    @Published private(set) var flash: OutputReport?

    var onHide: () -> Void = {}
    /// Opens the Settings window, optionally scrolled to a section.
    var onOpenSettings: (SettingsSection?) -> Void = { _ in }

    private var isHovering = false
    /// >0 while a modal we opened (folder picker) is up — don't collapse under it.
    private var holdCount = 0
    /// True during the flash's minimum on-screen time.
    private var flashHolding = false
    // hoverTask still used for collapse-grace scheduling; no longer used to expand (item 21).
    private var hoverTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    // item 21: hover-to-expand REMOVED. Only explicit click expands the island.
    static let hoverCloseGrace: Duration = .milliseconds(600)
    /// Opened from the menu bar while the pointer is elsewhere: close on its own.
    static let unattendedLinger: Duration = .seconds(4)
    static let flashDuration: Duration = .milliseconds(1500)

    init(metrics: IslandMetrics) {
        self.metrics = metrics
    }

    // item 21: hover tracking is kept ONLY for collapse-grace and flash-hold
    // checks. We no longer expand on hover — only on explicit click/tap.
    func hoverChanged(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverTask?.cancel()
        if hovering {
            // DEBUG override: `defaults write com.ivanbayu.meetingrecorder
            // debugHoverExpand -bool true` restores hover-to-expand for
            // animation inspection. Off by default (item 21 kept click-only).
            guard UserDefaults.standard.bool(forKey: "debugHoverExpand") else { return }
            expand()
            return
        }
        // Grace window: if the pointer left while expanded, schedule collapse.
        scheduleCollapse(after: Self.hoverCloseGrace)
    }

    /// Chevron / status-item click: instant, no delays. Only way to expand.
    func toggleExpanded() {
        if isExpanded || flash != nil {
            collapseNow()
        } else {
            expand()
        }
    }

    func expand() {
        hoverTask?.cancel()
        setExpanded(true)
        if !isHovering { scheduleCollapse(after: Self.unattendedLinger) }
    }

    func collapseNow() {
        hoverTask?.cancel()
        flashTask?.cancel()
        flashHolding = false
        flash = nil
        isExpanded = false
    }

    /// Shows the result card, then collapses after `flashDuration` — unless the
    /// pointer is on the card (reading or clicking a link), in which case it
    /// waits for the pointer to leave.
    func presentSuccess(_ report: OutputReport) {
        flashTask?.cancel()
        flash = report
        flashHolding = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled, let self else { return }
            self.flashHolding = false
            guard !self.isHovering, self.holdCount == 0 else { return }
            self.collapseNow()
        }
    }

    func clearFlash() {
        flashTask?.cancel()
        flashHolding = false
        flash = nil
    }

    /// Keeps the card open around a synchronous modal (NSOpenPanel.runModal).
    func holdOpen(_ body: () -> Void) {
        holdCount += 1
        body()
        holdCount -= 1
        // The pointer is usually elsewhere once the modal closes; re-arm the close.
        if holdCount == 0 && !isHovering { scheduleCollapse(after: Self.hoverCloseGrace) }
    }

    private func setExpanded(_ value: Bool) {
        if value && !isExpanded { page = .main }
        isExpanded = value
    }

    private func scheduleCollapse(after delay: Duration) {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard !self.isHovering, self.holdCount == 0, !self.flashHolding else { return }
            self.collapseNow()
        }
    }
}

// MARK: - Island view

struct NotchIslandView: View {
    @ObservedObject var manager: MeetingManager
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the card body shows. (Not "Body" — that name is View's associated type.)
    enum Pane: Hashable { case outputs, history, processing, review, success, failure }

    /// One-by-one content reveal: when the card expands, elements flip from
    /// hidden to visible with a 0.05s step (staggeredReveal); on collapse they
    /// all exit fast without stagger.
    @State private var reveal = false
    // Hover state drives target scale and recording waveform/stop swap.
    @State private var recordHovering = false
    @State private var chevronHovering = false
    @State private var clockHovering = false

    private struct LayoutKey: Equatable {
        var open: Bool
        var pane: Pane
        var recording: Bool
    }

    private var metrics: IslandMetrics { model.metrics }

    /// Priority: an active pipeline or a blocker outranks whatever page the user was on.
    private var currentPane: Pane {
        if manager.isProcessing { return .processing }
        if manager.pendingReview != nil { return .review }
        if manager.errorMessage != nil { return .failure }
        if model.flash != nil { return .success }
        return model.page == .history ? .history : .outputs
    }

    /// States that hold the card open regardless of hover.
    private func isPinned(_ pane: Pane) -> Bool {
        pane == .processing || pane == .review || pane == .failure || pane == .success
    }

    var body: some View {
        let content = currentPane
        let open = model.isExpanded || isPinned(content)
        let recording = manager.isRecording

        card(open: open, content: content, recording: recording)
            .frame(width: metrics.panelSize.width, height: metrics.panelSize.height, alignment: .top)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
            .environmentObject(manager)
            // One easing drives every layout change: Emil's strong ease-out,
        // longer on enter (expand), shorter on exit (collapse). Reduce Motion:
        // the shape snaps (no movement); content still crossfades.
            .animation(reduceMotion ? nil : (open ? IslandMotion.expand : IslandMotion.collapse),
                       value: LayoutKey(open: open, pane: content, recording: recording))
            // onChange, not onReceive: a publisher built inside body is re-subscribed on every
            // render and replays lastReport, so presentSuccess → re-render → replay looped forever.
            .onChange(of: manager.lastReport) { _, report in
                if let report { model.presentSuccess(report) }
            }
            // One-by-one reveal: on open (or page switch) reset and re-run the
            // stagger; on close everything just fades out fast (no stagger).
            .onChange(of: model.isExpanded) { _, open in
                restartReveal(open: open)
            }
            .onChange(of: model.page) { _, _ in
                restartReveal(open: model.isExpanded)
            }
    }

    // MARK: Card

    private func card(open: Bool, content: Pane, recording: Bool) -> some View {
        // Square top corners in BOTH states: the island hangs from the screen
        // edge like the notch itself. Only the bottom radius changes.
        let shape = IslandShape(
            topRadius: 0,
            bottomRadius: open ? IslandMetrics.expandedBottomRadius : IslandMetrics.collapsedBottomRadius
        )
        let width = open ? metrics.expandedWidth : metrics.collapsedWidth(recording: recording)

        return VStack(spacing: 0) {
            topRow(open: open, content: content, recording: recording)
                .frame(width: width, height: metrics.topBarHeight)

            // Body is laid out at full card width from the first frame and revealed
            // by the growing clip — it never reflows mid-animation. ZStack (not
            // VStack) so an outgoing and incoming body overlap during a crossfade.
            ZStack(alignment: .top) {
                if open {
                    page(content)
                        .id(content)
                        .transition(contentTransition)
                }
            }
            .frame(width: metrics.expandedWidth, alignment: .top)
            .modifier(ClampedHeight(height: open ? bodyHeight(content) : 0))
        }
        .frame(width: width, alignment: .top)
        // Pure black in both states — no material — so it reads as the notch.
        .background(Color.black)
        .clipShape(shape)
        // Ears sit outside the clip so the top corners curve out into the menu bar.
        .overlay(alignment: .topLeading) { ear.offset(x: -IslandMetrics.earRadius) }
        .overlay(alignment: .topTrailing) { ear.scaleEffect(x: -1).offset(x: IslandMetrics.earRadius) }
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 18, x: 0, y: 10)
        // item 34: pill-wide overlay REMOVED — per-element hover fills are on
        // RecordControlButton, chevron, and collapsedClock individually.
        .contentShape(shape)
        // item 21 / 34: onContinuousHover feeds collapse-grace only; no expand, no pill fill.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                model.hoverChanged(true)
            case .ended:
                model.hoverChanged(false)
            }
        }
    }

    private var ear: some View {
        IslandEar()
            .fill(Color.black)
            .frame(width: IslandMetrics.earRadius, height: IslandMetrics.earRadius)
            .allowsHitTesting(false)
    }

    private var contentTransition: AnyTransition {
        // Whole-page fade only — the one-by-one reveal of the inner elements
        // is handled per-row by StaggerReveal below. No delay here: a delayed
        // whole page would double up with the row stagger.
        .asymmetric(
            insertion: .opacity.animation(IslandMotion.contentIn),
            removal: .opacity.animation(IslandMotion.contentOut)
        )
    }

    private func restartReveal(open: Bool) {
        reveal = false
        guard open else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            reveal = true
        }
    }

    /// One-by-one reveal (Ivan's 2026-11-18 request): on expand, each element
    /// fades + slides up 6pt IN ORDER with a 0.05s step. On collapse everything
    /// exits fast without stagger. Reduce Motion: opacity only, no slide.
    private struct StaggerReveal: ViewModifier {
        var index: Int
        var active: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func body(content: Content) -> some View {
            content
                .opacity(active ? 1 : 0)
                .offset(y: active || reduceMotion ? 0 : 6)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.1)
                    : .easeOut(duration: 0.18).delay(active ? 0.05 + Double(index) * 0.05 : 0),
                    value: active
                )
        }
    }

    private func bodyHeight(_ content: Pane) -> CGFloat {
        switch content {
        case .outputs, .history: return IslandMetrics.maxBodyHeight
        case .processing: return 40
        // 4 top + 24 headline + 16 title + 16 details + 10 + 26 buttons + 12 bottom.
        case .review: return 108
        // Items 29 + 42: 12pt bottom inset with space for the card contents.
        case .failure: return 116
        case .success: return successHeight(model.flash)
        }
    }

    private func successHeight(_ report: OutputReport?) -> CGFloat {
        // One headline row (matches the 40pt processing row) + a line per failure.
        let failures = CGFloat(report?.failures.count ?? 0)
        return min(IslandMetrics.maxBodyHeight, 40 + failures * 22)
    }

    // MARK: Top row

    /// Icon-only: record/stop on the left wing; chevron (or, while collapsed and
    /// recording, the live timer + blinking dot) on the right wing. On a notched
    /// screen the camera housing sits in the Spacer between the wings.
    ///
    /// Each interactive target scales on hover; island-level continuous hover
    /// still controls collapse grace.
    private func topRow(open: Bool, content: Pane, recording: Bool) -> some View {
        HStack(spacing: 0) {
            recordControl(open: open)
                .modifier(ElementHoverScale(isHovering: $recordHovering,
                                            enabled: !manager.isProcessing && groqKeyValid,
                                            cornerRadius: metrics.controlCornerRadius))
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if recording && !open {
                    // Collapsed + recording: blinking dot + timer (items 22, 24)
                    collapsedClock
                        .modifier(ElementHoverScale(isHovering: $clockHovering,
                                                    cornerRadius: metrics.controlCornerRadius,
                                                    scales: false))
                        .transition(.opacity)
                } else {
                    chevron(open: open, content: content)
                        .modifier(ElementHoverScale(
                            isHovering: $chevronHovering,
                            enabled: !(content == .processing || content == .review || content == .failure),
                            cornerRadius: metrics.controlCornerRadius
                        ))
                        .transition(.opacity)
                }
            }
        }
        // Same inset open or collapsed: glyphs land ~11pt in, on the body's 12pt text edge.
        .padding(.horizontal, metrics.controlEdgeInset)
    }

    // MARK: Record control (items 19 + 25)

    private func recordControl(open: Bool) -> some View {
        RecordControlButton(
            isRecording: manager.isRecording,
            isProcessing: manager.isProcessing,
            groqKeyValid: groqKeyValid,
            isHovered: recordHovering,
            recorder: manager.audioRecorder,
            action: { toggleRecording() }
        )
    }

    /// True when the Groq key is present and verified (item 13 island side).
    /// ORCHESTRATOR-GLUE: manager.groqKeyState must conform to GroqKeyState pattern-matched below.
    private var groqKeyValid: Bool {
        // DEBUG override: `defaults write com.ivanbayu.meetingrecorder
        // debugSkipGroqGate -bool true` opens the record gate for animation
        // inspection without a verified key.
        if UserDefaults.standard.bool(forKey: "debugSkipGroqGate") { return true }
        if case .valid = manager.groqKeyState { return true }
        return false
    }

    /// Live timer + blinking dot in the collapsed right wing (items 22, 24).
    /// Clicking the timer opens the card.
    @ViewBuilder
    private var collapsedClock: some View {
        if let start = manager.recordingStartedAt {
            // Dot + time are ONE box (one button, one highlight), same 7pt inset as the glyphs.
            Button { model.toggleExpanded() } label: {
                HStack(spacing: 5) {
                    BlinkingDot()
                    RecordingClock(start: start)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, IslandMetrics.controlContentInset)
                .frame(height: IslandMetrics.controlSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand")
            .accessibilityLabel("Recording time")
        }
    }

    private func chevron(open: Bool, content: Pane) -> some View {
        Button { model.toggleExpanded() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
                .rotationEffect(.degrees(open ? 180 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        // Can't fold away a running pipeline or an unacknowledged blocker.
        .disabled(content == .processing || content == .review || content == .failure)
        .help(open ? "Collapse" : "Expand")
        .accessibilityLabel(open ? "Collapse" : "Expand")
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ content: Pane) -> some View {
        switch content {
        case .outputs: outputsPage
        case .history: historyPage
        case .processing: processingPage
        case .review: reviewPage
        case .success: successPage(model.flash)
        case .failure: failurePage
        }
    }

    // MARK: Outputs page (items 13 island, 27)

    private var outputsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // item 13 island side: Groq onboarding card shown when key is missing/unverified
            if !groqKeyValid {
                GroqOnboardingCard(manager: manager)
                    .modifier(StaggerReveal(index: 0, active: reveal))
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }

            Text("SEND NOTES TO")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(height: 16)
                .padding(.horizontal, 8)
                .modifier(StaggerReveal(index: 1, active: reveal))

            // item 27: roomier row spacing in the send-notes section
            VStack(spacing: 4) {
                ForEach(Array(OutputDestination.allCases.enumerated()), id: \.element) { offset, destination in
                    DestinationRow(
                        icon: destination.systemImage,
                        title: destination.title,
                        caption: caption(for: destination),
                        isSelected: manager.activeDestination == destination,
                        isReady: manager.isReady(destination),
                        select: { manager.select(destination) },
                        accessory: accessory(for: destination)
                    )
                    .modifier(StaggerReveal(index: 2 + offset, active: reveal))
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 6)
            bottomBar
                .modifier(StaggerReveal(index: 5, active: reveal))
        }
        // item 27: 4 outer + 8 row inset = 12pt text inset, matching the top row.
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(width: metrics.expandedWidth, height: IslandMetrics.maxBodyHeight, alignment: .top)
    }

    private func caption(for destination: OutputDestination) -> String? {
        switch destination {
        case .markdown: return manager.markdownConfigured ? "Folder: \(manager.markdownFolderName)" : nil
        case .googleDocs: return manager.googleConfigured ? "Folder: Meeting Notes" : nil
        case .notion, .clipboard: return nil
        }
    }

    /// Setup first: an unconfigured row shows its setup action; Markdown keeps
    /// a "Directory" action once a folder is chosen (item 33: no ellipsis in copy).
    /// No key-entry microcopy here — Notion setup happens in Settings.
    private func accessory(for destination: OutputDestination) -> DestinationRow.Accessory? {
        switch destination {
        case .notion:
            guard !manager.notionConfigured else { return nil }
            return DestinationRow.Accessory(title: "Connect Notion") { model.onOpenSettings(.notion) }
        case .googleDocs:
            guard !manager.googleConfigured else { return nil }
            return DestinationRow.Accessory(title: manager.googleConnecting ? "Waiting for browser…" : "Connect Google") {
                manager.connectGoogle()
            }
        case .markdown:
            // item 33: "Change…" → "Directory" (no ellipsis in copy once configured)
            return DestinationRow.Accessory(title: manager.markdownConfigured ? "Directory" : "Choose directory") {
                chooseMarkdownFolder()
            }
        case .clipboard:
            return nil
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            if manager.isRecording, let start = manager.recordingStartedAt {
                Button {
                    Task { await manager.stopRecording() }
                } label: {
                    HStack(spacing: 8) {
                        RecordFace(kind: .stop, pulses: true, diameter: 18)
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                        RecordingClock(start: start)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.red.opacity(0.22)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Stop recording")
                // Items 43 + 44: the red capsule is the visible edge here, and it
                // sat at the 4pt outer inset — 12pt from the bottom but only 4pt
                // from the side, crowding the 20pt corner. +8 → 12pt side ==
                // 12pt bottom, and the Stop shifts right onto the card's 12pt
                // rhythm (top-row controls, row text). Padding sits outside the
                // Button so the press-scale anchor/hit area are unchanged.
                .padding(.leading, 8)

                // item 20 island: mic level meter, hidden when not recording
                MicLevelBar(level: manager.audioRecorder.micLevel)
                    .transition(.opacity.animation(IslandMotion.contentIn))

                Spacer(minLength: 0)
                if !manager.meetingHistory.isEmpty {
                    IslandIconButton(systemName: "clock.arrow.circlepath", help: "History (\(manager.meetingHistory.count))") {
                        model.page = .history
                    }
                }
            } else {
                if !manager.meetingHistory.isEmpty {
                    Button { model.page = .history } label: {
                        Label("History (\(manager.meetingHistory.count))", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Spacer(minLength: 0)
            }

            IslandIconButton(systemName: "gearshape", help: "Settings") {
                model.onOpenSettings(nil)
            }
            IslandIconButton(systemName: "xmark.circle", help: "Hide island — keeps running; reopen from the menu bar") {
                model.onHide()
            }
        }
        .frame(height: 30)
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { model.page = .main } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                Spacer()
                Text("History")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(.horizontal, 8)
            .modifier(StaggerReveal(index: 0, active: reveal))

            HistoryView()
                .modifier(StaggerReveal(index: 1, active: reveal))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .frame(width: metrics.expandedWidth, height: IslandMetrics.maxBodyHeight, alignment: .top)
    }

    /// After summarising: the user decides. Discard asks for confirmation first.
    private var reviewPage: some View {
        let meeting = manager.pendingReview
        let summary = meeting?.summary
        let details = [
            summary?.keyPoints.flatMap { $0.isEmpty ? nil : "\($0.count) key points" },
            summary.flatMap { $0.actionPoints.isEmpty ? nil : "\($0.actionPoints.count) action items" },
            summary.flatMap { $0.keyDecisions.isEmpty ? nil : "\($0.keyDecisions.count) decisions" },
        ].compactMap { $0 }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green)
                Text("Notes ready")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(height: 24)
            Group {
                Text(meeting?.title ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text(details.isEmpty ? "Summary ready" : details)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 22) // under the headline text, past the checkmark
            .frame(height: 16, alignment: .leading)

            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Button("Discard") {
                    model.holdOpen { manager.confirmDiscardPendingNotes() }
                }
                .buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
                Button(manager.uploadActionTitle) {
                    Task { await manager.uploadPendingNotes() }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, IslandMetrics.horizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(width: metrics.expandedWidth, height: 108, alignment: .topLeading)
    }

    private var processingPage: some View {
        // One row: stage on the left, destination on the right — keeps the card short.
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            // Baseline-aligned: 14pt and 11pt text centred on their boxes look misaligned.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(manager.processingStage.isEmpty ? "Working…" : manager.processingStage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 8)
                // "Saving to Notion…" already names the destination; don't repeat it.
                if !manager.processingStage.hasPrefix("Saving") {
                    Text(destinationsLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
        .frame(height: 24)
        .padding(.horizontal, IslandMetrics.horizontalPadding)
        .padding(.top, 4) // row 4…28 in the 40pt body: 12pt below, matching the side insets
        .frame(width: metrics.expandedWidth, height: 40, alignment: .topLeading)
    }

    private var destinationsLine: String {
        if let destination = manager.activeDestination {
            return "Then: \(destination.title)"
        }
        return "No destination set up — notes will stay in History"
    }

    private func successPage(_ report: OutputReport?) -> some View {
        // One row, mirroring the processing row it replaces: ✓ headline on the left,
        // "open" on the right. Only one destination is ever active, so one headline fits.
        let headline: String
        var open: (url: URL, help: String)? = nil
        if let url = report?.notionURL {
            headline = "Saved to Notion"; open = (url, "Open in Notion")
        } else if let url = report?.googleDocURL {
            headline = "Saved to Google Docs"; open = (url, "Open in Google Docs")
        } else if let url = report?.markdownURL {
            headline = "Saved \(url.lastPathComponent)"; open = (url, "Open the Markdown file")
        } else if report?.copied == true {
            headline = "Copied to clipboard"
        } else if report?.nothingEnabled == true {
            headline = "Kept in History"
        } else {
            headline = "Saved"
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green)
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let open {
                    OpenLinkButton(help: open.help) { NSWorkspace.shared.open(open.url) }
                }
            }
            .frame(height: 24)

            ForEach(report?.failures ?? [], id: \.self) { failure in
                ResultLine(icon: "exclamationmark.triangle.fill", text: failure, tint: .yellow)
            }
        }
        .padding(.horizontal, IslandMetrics.horizontalPadding)
        .padding(.top, 4)
        .frame(width: metrics.expandedWidth, height: successHeight(report), alignment: .topLeading)
    }

    // MARK: Failure page (item 26: wider horizontal padding ~15pt)

    private var failurePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.red)
                Text(manager.errorMessage ?? "Something went wrong.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") {
                    manager.dismissFailure()
                    model.collapseNow()
                }
                .buttonStyle(PillButtonStyle())
                if manager.canRetry {
                    Button("Retry") {
                        Task { await manager.retryProcessing() }
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
        // item 26: 15pt horizontal padding — text cards get a bit more room than the 12pt default
        // item 29: 14pt bottom padding — matches the left/right 12-15pt rhythm
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(width: metrics.expandedWidth, height: 116, alignment: .topLeading)
    }

    // MARK: Actions

    private func toggleRecording() {
        if manager.isRecording {
            Task { await manager.stopRecording() }
        } else {
            model.clearFlash()
            Task { await manager.startRecording() }
        }
    }

    private func chooseMarkdownFolder() {
        model.holdOpen {
            manager.chooseMarkdownFolder()
        }
    }
}

// MARK: - Groq onboarding card (item 13 — island side)

/// Shown at the top of the outputs page when groqAPIKey is empty or the key
/// state is idle/error. The record control is disabled while this is showing.
struct GroqOnboardingCard: View {
    @ObservedObject var manager: MeetingManager
    // ORCHESTRATOR-GLUE: manager.groqKeyState: GroqKeyState, manager.verifyGroqKey() async -> Bool

    @State private var isVerifying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add your Groq API key")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))

            SecureField("sk-…", text: $manager.groqAPIKey)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )

            HStack(spacing: 8) {
                Button {
                    isVerifying = true
                    Task {
                        _ = await manager.verifyGroqKey()
                        isVerifying = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isVerifying {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Save & Verify")
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                .disabled(manager.groqAPIKey.isEmpty || isVerifying)

                // Inline status chip: ✓ green / ✗ error line
                groqKeyStatusView
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var groqKeyStatusView: some View {
        switch manager.groqKeyState {
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.green)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
                .lineLimit(1)
                .truncationMode(.tail)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Record control button (items 19 + 25)

/// The record/stop control in the top-left wing.
/// Item 19: NO red circle background. Glyph is RED while recording, WHITE while idle.
/// Item 38: the parent topRow applies the scale hover affordance.
/// Item 13: Disabled (greyed) when groqKeyValid is false.
struct RecordControlButton: View {
    var isRecording: Bool
    var isProcessing: Bool
    var groqKeyValid: Bool
    var isHovered: Bool
    @ObservedObject var recorder: AudioRecorder
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Glyph { case mic, wave, stop, busy }
    private var glyph: Glyph {
        if isProcessing { return .busy }
        if !isRecording { return .mic }
        return isHovered ? .stop : .wave
    }

    var body: some View {
        Button(action: action) {
            // All four glyphs stay mounted and cross-morph (scale + blur + fade) on one
            // spring, so mic → waveform → stop is one continuous, interruptible motion.
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .offset(y: -1) // mic.fill's stand pulls its optical centre low
                    .modifier(GlyphMorph(visible: glyph == .mic, reduceMotion: reduceMotion))
                RecordingWaveform(level: recorder.audioLevel, active: glyph == .wave)
                    .modifier(GlyphMorph(visible: glyph == .wave, reduceMotion: reduceMotion))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .modifier(GlyphMorph(visible: glyph == .stop, reduceMotion: reduceMotion))
                ProgressView()
                    .controlSize(.mini)
                    .modifier(GlyphMorph(visible: glyph == .busy, reduceMotion: reduceMotion))
            }
            // Glyph centred in its box; the box (= hover highlight) is square for mic/stop
            // and widens for the 21pt waveform, keeping the same 7pt inset each side.
            .frame(width: glyph == .wave ? 21 + 2 * IslandMetrics.controlContentInset : IslandMetrics.controlSize,
                   height: IslandMetrics.controlSize)
            .animation(reduceMotion ? IslandMotion.reducedFade : .spring(duration: 0.3, bounce: 0.2), value: glyph)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        // item 13 island: disable while Groq key missing/invalid; also while processing
        .disabled(isProcessing || !groqKeyValid)
        .help(isRecording ? "Stop recording" : (groqKeyValid ? "Start recording" : "Add a Groq API key to record"))
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Outgoing glyph shrinks, blurs and fades; incoming does the reverse. Blur makes
/// the shapes melt into each other instead of reading as two overlapping icons.
struct GlyphMorph: ViewModifier {
    var visible: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible || reduceMotion ? 1 : 0.55)
            .blur(radius: visible || reduceMotion ? 0 : 3)
    }
}

/// Five red bars driven by the live audio level (mic + system). Silence rests
/// at a low floor; speech lifts the bars in a centre-weighted shape, with a
/// little per-bar wobble so loud passages don't look like one block.
struct RecordingWaveform: View {
    /// 0…1 from AudioRecorder.audioLevel.
    var level: Float
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
    private let floor: CGFloat = 0.22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // sqrt lifts quiet speech so normal talking visibly moves the bars.
            let lvl = CGFloat(sqrt(max(0, min(level, 1))))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = reduceMotion ? 1 : 0.8 + 0.2 * CGFloat(sin(t * 9 + Double(i) * 1.7))
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 2.5, height: 15)
                        .scaleEffect(y: floor + (1 - floor) * lvl * shape[i] * wobble, anchor: .center)
                }
            }
            .animation(.easeOut(duration: 0.1), value: level)
            .frame(width: 21, height: 20)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Components

/// Record button face. Item 19: NO red circle background — glyph color carries
/// the semantic (red = recording/stop, white = idle/mic). The glyph morphs
/// mic → stop (and back) as a scale + opacity crossfade on `IslandMotion.glyphSwap`
/// (~0.2s, one small overshoot). Both glyphs stay mounted so the swap is
/// interruptible. Reduce Motion: opacity only.
struct RecordFace: View {
    enum Kind: Equatable { case mic, stop }
    var kind: Kind
    var pulses: Bool
    var diameter: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStop = kind == .stop
        // Outgoing glyph shrinks toward 0.5 (never 0) while fading.
        let hiddenScale: CGFloat = reduceMotion ? 1 : 0.5
        // item 19: glyph is red when showing the stop square; white for mic.
        let glyphColor: Color = isStop ? .red : .white

        ZStack {
            // item 19: Circle().fill(Color.red) REMOVED — no background circle.
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: diameter * 0.6, weight: .semibold))
                    .scaleEffect(isStop ? hiddenScale : 1)
                    .opacity(isStop ? 0 : 1)
                RoundedRectangle(cornerRadius: diameter * 0.1, style: .continuous)
                    .frame(width: diameter * 0.38, height: diameter * 0.38)
                    .scaleEffect(isStop ? 1 : hiddenScale)
                    .opacity(isStop ? 1 : 0)
            }
            .animation(reduceMotion ? IslandMotion.reducedFade : IslandMotion.glyphSwap, value: kind)
        }
        .foregroundStyle(glyphColor)
        .animation(reduceMotion ? IslandMotion.reducedFade : IslandMotion.glyphSwap, value: isStop)
        .frame(width: diameter, height: diameter)
        .modifier(PulseEffect(active: pulses))
        .accessibilityHidden(true)
    }
}

/// Scale 1.0↔1.12 + opacity 0.9↔1.0, 0.8s ease-in-out, forever.
/// Transform/opacity only (compositor-friendly). Off under Reduce Motion.
/// Turning `active` off swaps the repeating animation for a short settle,
/// which ends the repeat cleanly instead of freezing mid-pulse.
struct PulseEffect: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    func body(content: Content) -> some View {
        let running = active && !reduceMotion
        content
            .scaleEffect(running && phase ? 1.12 : 1)
            .opacity(running ? (phase ? 1 : 0.9) : 1)
            .animation(running ? IslandMotion.pulse : IslandMotion.contentOut, value: phase)
            .task(id: running) { phase = running }
    }
}

// MARK: - Blinking dot (item 24)

/// Small red dot shown next to the timer while recording. Blinks at a steady
/// ~1s cadence (opacity 0.2 ↔ 1.0, 0.5s each half = 1s full cycle).
/// Reduce Motion: static dot, no animation.
struct BlinkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinkPhase = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1.0 : (blinkPhase ? 1.0 : 0.2))
            .animation(reduceMotion ? nil : IslandMotion.blink, value: blinkPhase)
            .onAppear {
                guard !reduceMotion else { return }
                blinkPhase = true
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Mic level meter (item 20 — island side)

/// A compact 5-bar level meter rendered next to the Stop button in the bottom
/// bar while recording. Transform/opacity only (Emil-style). The caller
/// conditionally shows this view with a .transition(.opacity) for clean in/out.
struct MicLevelBar: View {
    /// 0…1, published by AudioRecorder at ~10 Hz.
    /// ORCHESTRATOR-GLUE: manager.audioRecorder.micLevel: Float
    var level: Float

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 14
    private let minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let threshold = Float(i) / Float(barCount)
                let lit = level > threshold
                let heightFraction = CGFloat(i + 1) / CGFloat(barCount)
                let barH = minHeight + (maxHeight - minHeight) * heightFraction
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(lit ? Color.green : Color.white.opacity(0.15))
                    .frame(width: barWidth, height: barH)
                    // Transform only: scale vertically from center
                    .scaleEffect(y: lit ? 1.0 : 0.6, anchor: .bottom)
                    .animation(IslandMotion.contentIn, value: lit)
            }
        }
        .frame(height: maxHeight)
        .accessibilityHidden(true)
    }
}

/// mm:ss (h:mm:ss past an hour), ticking once a second. Digits are monospaced
/// and the change is not animated — it's live data, not decoration.
struct RecordingClock: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .monospacedDigit()
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// One radio row under "SEND NOTES TO". Setup first: until a destination is
/// set up its radio is dimmed and inert, and the trailing accessory
/// ("Connect Notion…" / "Choose folder…") is the only live control.
/// Custom rather than a Picker: native radios render inactive (grey) in a
/// panel that never becomes key, which is exactly this panel.
struct DestinationRow: View {
    struct Accessory {
        let title: String
        let action: () -> Void
    }

    let icon: String
    let title: String
    var caption: String? = nil
    let isSelected: Bool
    let isReady: Bool
    let select: () -> Void
    var accessory: Accessory? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 10) {
                    RadioDot(isOn: isSelected)
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white)
                        if let caption {
                            Text(caption)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                }
                // item 27: roomier vertical padding in destination rows
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isReady)
            .opacity(isReady ? 1 : 0.4)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected" : (isReady ? "Not selected" : "Not set up"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let accessory {
                // item 33: accessory label must never truncate — fixedSize lets
                // the button take as much width as its text needs.
                Button(accessory.title, action: accessory.action)
                    .fixedSize(horizontal: true, vertical: false)
                    .buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 8)
        // item 27: slightly taller row for breathing room
        .frame(minHeight: 32)
        // Hover tint is instant: rows are scanned many times a day.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering && isReady ? 0.10 : 0))
        )
        .onHover { hovering = $0 }
    }
}

/// Radio indicator. The inner dot scales in from 0.5 with the short press
/// ease-out — click feedback, not decoration.
struct RadioDot: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? Color.accentColor : Color.white.opacity(0.35), lineWidth: 1.5)
            Circle()
                .fill(Color.accentColor)
                .padding(4)
                .scaleEffect(isOn ? 1 : 0.5)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .animation(IslandMotion.press, value: isOn)
    }
}

/// One outcome line in the success card, optionally with an open-link button.
struct ResultLine: View {
    let icon: String
    let text: String
    var tint: Color = .white
    var actionHelp: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint.opacity(0.75))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let action {
                OpenLinkButton(help: actionHelp ?? "Open", action: action)
            }
        }
        .frame(height: 22)
    }
}

/// Small round ↗ button that opens a saved result.
struct OpenLinkButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IslandIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Press feedback on press-down: a small scale, 100ms strong ease-out. No bounce.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(IslandMotion.press, value: configuration.isPressed)
    }
}

/// Capsule text button. Custom so "prominent" keeps its accent colour in a
/// non-key panel (system bordered-prominent greys out when the window is inactive).
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    /// Smaller variant for inline row actions ("Connect Notion…", "Choose folder…").
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(compact ? 0.85 : 1))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 22 : 26)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(0.12)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(IslandMotion.press, value: configuration.isPressed)
    }
}

// MARK: - History

/// Compact history list for the island card. Reads the same Meeting fields as before.
struct HistoryView: View {
    @EnvironmentObject var manager: MeetingManager

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(manager.meetingHistory) { meeting in
                    HistoryRow(meeting: meeting)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(meeting.startDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            if let urlString = meeting.notionPageURL, let url = URL(string: urlString) {
                IslandIconButton(systemName: "n.square", help: "Open in Notion") {
                    NSWorkspace.shared.open(url)
                }
            }
            if let fileURL = meeting.markdownFileURL {
                IslandIconButton(systemName: "doc.text", help: "Open Markdown file") {
                    NSWorkspace.shared.open(fileURL)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .help(meeting.summary?.summary ?? meeting.status.rawValue)
    }

    private var statusIcon: String {
        switch meeting.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .recording: return "record.circle.fill"
        default: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch meeting.status {
        case .completed: return .green
        case .failed, .recording: return .red
        default: return .orange
        }
    }
}

// MARK: - Panel

/// Hosting view that takes the first click even though the panel is never key,
/// so a single click on the island acts immediately.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating panel pinned to the top-centre of the menu-bar
/// screen. Created once; show/hide only order it in and out. The panel is the
/// max card size (plus shadow margin) and fully transparent — the SwiftUI view
/// draws the pill/card top-aligned inside it, so the window never resizes.
final class NotchIslandPanel: NSPanel {
    let model: IslandModel
    private var screenObserver: (any NSObjectProtocol)?

    /// The screen with the menu bar (and the notch, on a MacBook). NSScreen.main
    /// follows keyboard focus, which would make the island jump between displays.
    static var targetScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    init(manager: MeetingManager) {
        let metrics = IslandMetrics(screen: NotchIslandPanel.targetScreen)
        let model = IslandModel(metrics: metrics)
        self.model = model

        super.init(
            contentRect: NSRect(origin: .zero, size: metrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // One above .mainMenu so the pill is guaranteed to draw over the menu bar
        // rather than relying on same-level ordering.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let host = IslandHostingView(rootView: NotchIslandView(manager: manager, model: model))
        host.sizingOptions = []
        contentView = host

        model.onHide = { [weak self] in self?.hide() }
        reposition()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.reposition() }
        }
    }

    // Must be key so the Groq key field can take typing; .nonactivatingPanel keeps the app from activating.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Borderless windows may sit over the menu bar; never let AppKit nudge it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func show(expanded: Bool = false) {
        reposition()
        orderFrontRegardless()
        if expanded { model.expand() }
    }

    func hide() {
        model.collapseNow()
        orderOut(nil)
    }

    func toggleExpanded() {
        if isVisible {
            model.toggleExpanded()
        } else {
            show(expanded: true)
        }
    }

    private func reposition() {
        let screen = Self.targetScreen
        let metrics = IslandMetrics(screen: screen)
        if metrics != model.metrics { model.metrics = metrics }
        guard let screen else { return }
        let size = metrics.panelSize
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
