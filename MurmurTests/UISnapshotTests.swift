import SwiftUI
import XCTest
@testable import Murmur

/// Renders each Settings tab, the Settings window and the HUD offscreen into PNG files for
/// visual review and for the README screenshots. Uses sample data only: no real Modes, usage
/// or Keychain key ever appears in a snapshot.
/// Skipped unless MURMUR_SNAPSHOT_DIR is set (pass TEST_RUNNER_MURMUR_SNAPSHOT_DIR to xcodebuild).
@MainActor
final class UISnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "Set MURMUR_SNAPSHOT_DIR to render UI snapshots")
        directory = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func environment<V: View>(_ view: V) -> some View {
        let suite = UserDefaults(suiteName: "murmur-snapshots-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: suite)
        let modes = ModeStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("snap-modes-\(UUID().uuidString).json"))
        let usage = UsageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("snap-usage-\(UUID().uuidString).json"))
        usage.recordTranscription(model: "gpt-transcribe", audioSeconds: 312, billedSeconds: 320)
        usage.recordModeProcessing(ModeOutput(text: "", model: "gpt-5.4-mini", inputTokens: 5400, cachedInputTokens: 0, outputTokens: 900))
        let permissions = Permissions()
        let apiKeys = APIKeyStore(key: nil)
        let dictation = DictationController(preferences: preferences, modes: modes, apiKeys: apiKeys, usage: usage, permissions: permissions)
        return view
            .environment(preferences)
            .environment(apiKeys)
            .environment(permissions)
            .environment(usage)
            .environment(ModelCatalog())
            .environment(modes)
            .environment(dictation)
    }

    private func render<V: View>(_ view: V, name: String, appearance: NSAppearance.Name) throws {
        let host = NSHostingController(rootView: environment(view))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.appearance = NSAppearance(named: appearance)
        window.styleMask = [.titled]
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        let view = host.view
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let suffix = appearance == .darkAqua ? "dark" : "light"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
    }

    func testRenderSettingsTabs() throws {
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsView())),
            ("dictation", AnyView(DictationSettingsView())),
            ("modes", AnyView(ModesSettingsView())),
            ("audio", AnyView(AudioSettingsView())),
            ("openai", AnyView(OpenAISettingsView())),
            ("usage", AnyView(UsageSettingsView())),
        ]
        for (name, view) in tabs {
            try render(view, name: name, appearance: .aqua)
        }
        try render(GeneralSettingsView(), name: "general", appearance: .darkAqua)
        try render(ModesSettingsView(), name: "modes", appearance: .darkAqua)
    }

    /// The whole Settings window, toolbar included, as the user sees it.
    private func renderWindow(_ tab: SettingsTab, appearance: NSAppearance.Name, selectingListRow row: Int? = nil) throws {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for item in SettingsTab.allCases {
            let host = NSHostingController(rootView: environment(settingsView(for: item)))
            host.sizingOptions = .preferredContentSize
            let tabItem = NSTabViewItem(viewController: host)
            tabItem.label = item.title
            tabItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
            tabs.addTabViewItem(tabItem)
        }
        tabs.selectedTabViewItemIndex = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: tab))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = tab.title
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let row, let table = firstSubview(of: NSTableView.self, in: window.contentView) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }

        let frame = try XCTUnwrap(window.contentView?.superview)
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let suffix = appearance == .darkAqua ? "dark" : "light"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("window-\(tab.rawValue)-\(suffix).png"))
    }

    private func settingsView(for tab: SettingsTab) -> AnyView {
        switch tab {
        case .general: AnyView(GeneralSettingsView())
        case .dictation: AnyView(DictationSettingsView())
        case .modes: AnyView(ModesSettingsView())
        case .audio: AnyView(AudioSettingsView())
        case .openAI: AnyView(OpenAISettingsView())
        case .usage: AnyView(UsageSettingsView())
        }
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    func testRenderSettingsWindows() throws {
        for tab in SettingsTab.allCases {
            // On the Modes tab, show the English example rather than the Default Mode.
            let row = tab == .modes ? 1 : nil
            try renderWindow(tab, appearance: .aqua, selectingListRow: row)
            try renderWindow(tab, appearance: .darkAqua, selectingListRow: row)
        }
    }

    /// The recording indicator while someone speaks, frame by frame, then the processing state:
    /// the frames of the README demo animation (see Scripts/make_readme_media.py). Every frame
    /// advances the level history by one sample, 80 ms apart.
    func testRenderDemoHUDFrames() throws {
        let speech: [Float] = [
            0.05, 0.08, 0.55, 0.7, 0.35, 0.8, 0.6, 0.2, 0.75, 0.9, 0.5, 0.15, 0.85, 0.7, 0.3, 0.65,
            0.8, 0.45, 0.6, 0.2, 0.5, 0.7, 0.4, 0.75, 0.55, 0.85, 0.6, 0.3, 0.1, 0.7, 0.9, 0.5,
            0.25, 0.1, 0.06, 0.05, 0.05, 0.05,
        ]
        let history = DictationController.levelHistory
        for frame in speech.indices {
            let levels = Array((Array(repeating: Float(0), count: history) + speech[...frame]).suffix(history))
            let elapsed = String(format: "0:%02d", Int(Double(frame) * 0.08))
            try renderHUD(sampleRecording(levels: levels, elapsed: elapsed, mode: "Default"), name: String(format: "demo-hud-%02d", frame))
        }
        let processing = HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Transcribing…")
                .font(.system(size: 13, weight: .medium))
        }
        .frame(height: 22)
        try renderHUD(processing, name: "demo-hud-processing")
    }

    /// Mirrors RecordingContent, whose levels and timer come from a live recording.
    private func sampleRecording(levels: [Float], elapsed: String, mode: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red.opacity(0.7), radius: 4)
            Waveform(levels: levels)
                .frame(width: 112, height: 22)
            Text(elapsed)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(mode)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.14), in: Capsule())
        }
    }

    /// Renders HUD content in its capsule on a transparent background.
    private func renderHUD<V: View>(_ content: V, name: String) throws {
        let hud = content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(white: 0.14).opacity(0.94))
                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            }
            .padding(24)
            .environment(\.colorScheme, .dark)

        let host = NSHostingController(rootView: hud)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        let view = host.view
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testRenderRecordingHUD() throws {
        let suite = UserDefaults(suiteName: "murmur-snapshots-\(UUID().uuidString)")!
        let modes = ModeStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("snap-modes-\(UUID().uuidString).json"))
        let dictation = DictationController(
            preferences: Preferences(defaults: suite), modes: modes, apiKeys: APIKeyStore(key: nil),
            usage: UsageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("snap-usage-\(UUID().uuidString).json")),
            permissions: Permissions()
        )
        let hud = RecordingContent(dictation: dictation, showModeMenu: {})
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(VisualEffectBackground().clipShape(Capsule(style: .continuous)))
            .padding(20)
            .environment(\.colorScheme, .dark)
        try render(hud, name: "hud-recording", appearance: .darkAqua)
    }
}
