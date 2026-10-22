import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, dictation, modes, audio, openAI, usage

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .modes: "Modes"
        case .audio: "Audio"
        case .openAI: "OpenAI"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "keyboard"
        case .modes: "wand.and.stars"
        case .audio: "mic"
        case .openAI: "key"
        case .usage: "chart.bar"
        }
    }
}

/// Lets settings views jump to another tab (e.g. "Add Key…" → OpenAI).
struct SettingsNavigator {
    var open: (SettingsTab) -> Void = { _ in }
}

private struct SettingsNavigatorKey: EnvironmentKey {
    static let defaultValue = SettingsNavigator()
}

extension EnvironmentValues {
    var settingsNavigator: SettingsNavigator {
        get { self[SettingsNavigatorKey.self] }
        set { self[SettingsNavigatorKey.self] = newValue }
    }
}

/// A standard macOS preferences window: toolbar tabs, each hosting a SwiftUI form.
/// While it is open Murmur shows a Dock icon, so the window behaves like any other
/// (⌘-Tab, Edit menu for copy & paste in text fields).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private let content: (SettingsTab) -> AnyView

    init(content: @escaping (SettingsTab) -> AnyView) {
        self.content = content
    }

    func show(_ tab: SettingsTab? = nil) {
        let window = self.window ?? makeWindow()
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in SettingsTab.allCases {
            let root = content(tab).environment(\.settingsNavigator, SettingsNavigator { [weak self] in self?.show($0) })
            let host = NSHostingController(rootView: root)
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("MurmurSettings") { window.center() }
        window.setFrameAutosaveName("MurmurSettings")
        self.window = window
        self.tabs = tabs
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar–only app; macOS returns focus to the previous app.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Secondary, leading-aligned explanation text under a settings section, like System Settings.
struct SettingsFootnote: View {
    private let text: Text

    init(_ text: String) {
        self.text = Text(text)
    }

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
