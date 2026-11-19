import SwiftUI
import AppKit
import AVFoundation
import os.log

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Placeholder so the App has a scene. The real Settings UI lives in an
        // app-owned NSWindow (SettingsWindowController): the SwiftUI Settings
        // scene's `showSettingsWindow:` action silently fails for `.accessory` apps.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: NotchIslandPanel?
    private var statusItem: NSStatusItem?
    private let meetingManager = MeetingManager.shared
    private let logger = Logger(subsystem: "MeetingRecorder", category: "AppDelegate")

    /// Quit while recording/processing: save the audio first (Retry after relaunch).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meetingManager.isRecording || meetingManager.isProcessing else { return .terminateNow }
        Task { @MainActor in
            await meetingManager.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MeetingRecorder launched")
        // Menu-bar-only app: hide the Dock icon.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()

        let island = NotchIslandPanel(manager: meetingManager)
        island.model.onOpenSettings = { section in AppActions.openSettings(section: section) }
        self.island = island
        if meetingManager.autoShowIsland {
            island.show()
        }

        requestMicrophoneAccessIfNeeded()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            logger.error("Status item button is nil — menu bar icon not created")
            return
        }
        button.image = MenuBarIcon.make()
        button.imagePosition = .imageOnly
        button.toolTip = "Meeting Transcriber"
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showMenu()
        } else {
            // Hidden → show it open. Visible → open/close the card.
            island?.toggleExpanded()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(makeItem("Show Recorder", #selector(showRecorder)))
        menu.addItem(makeItem("Hide Island", #selector(hideIsland)))
        menu.addItem(.separator())

        let launchItem = makeItem("Open Island on Launch", #selector(toggleAutoShowIsland))
        launchItem.state = meetingManager.autoShowIsland ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(makeItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Meeting Transcriber", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        // Attach only for this click so a left click keeps going to the island.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showRecorder() {
        island?.show(expanded: true)
    }

    @objc private func hideIsland() {
        island?.hide()
    }

    @objc private func toggleAutoShowIsland() {
        meetingManager.autoShowIsland.toggle()
    }

    @objc private func openSettings() {
        AppActions.openSettings()
    }

    // MARK: - Permissions

    /// Microphone is its own TCC permission: ask once, only while undecided.
    /// Screen & System Audio is NOT touched at launch — MeetingManager asks on
    /// the first Record press and shows an in-app card if it's missing.
    private func requestMicrophoneAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        let logger = self.logger
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { logger.warning("Microphone access denied") }
        }
    }
}

// MARK: - Settings window

/// Hosts SettingsView in an app-owned NSWindow. Created lazily, then reused —
/// one window for the app's lifetime, shown from the island gear and the
/// menu-bar "Settings…" item.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(section: SettingsSection? = nil) {
        let manager = MeetingManager.shared
        if let section { manager.settingsFocus = section }

        let window = self.window ?? makeWindow(manager: manager)
        self.window = window

        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(manager: MeetingManager) -> NSWindow {
        let host = NSHostingView(rootView: SettingsView().environmentObject(manager))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: SettingsView.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Transcriber Settings"
        window.contentView = host
        window.isReleasedWhenClosed = false
        // Regular level even though the app is .accessory, and follows the user
        // to the current Space instead of yanking them back.
        window.collectionBehavior = [.moveToActiveSpace]
        return window
    }
}

// MARK: - Shared actions

@MainActor
enum AppActions {
    static func openSettings(section: SettingsSection? = nil) {
        SettingsWindowController.shared.show(section: section)
    }
}

@MainActor
enum FolderPicker {
    /// Folder chooser (NSOpenPanel with directories only). Starts in the
    /// current folder, or `~/Documents/MeetingNotes` (created on demand) when
    /// none is chosen yet. Returns an absolute path, or nil if cancelled.
    static func choose(startingAt current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where meeting notes are saved"

        let fm = FileManager.default
        let currentURL = MarkdownExporter.folderURL(from: current)
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.createDirectory(at: currentURL, withIntermediateDirectories: true)
        }
        panel.directoryURL = fm.fileExists(atPath: currentURL.path)
            ? currentURL
            : currentURL.deletingLastPathComponent()

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }
}
