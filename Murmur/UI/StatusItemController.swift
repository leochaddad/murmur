import AppKit

/// Murmur's menu bar item: shows idle / listening / processing state and offers quick
/// Mode switching. The menu is rebuilt each time it opens, so it always reflects the current state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    var openSettings: ((SettingsTab?) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let dictation: DictationController
    private let modes: ModeStore
    private let preferences: Preferences
    private let usage: UsageStore
    private let permissions: Permissions
    private let apiKeys: APIKeyStore

    private var animationTimer: Timer?
    private var animationPhase = 0.0
    private var levels: [Float] = Array(repeating: 0, count: 5)

    init(dictation: DictationController, modes: ModeStore, preferences: Preferences, usage: UsageStore, permissions: Permissions, apiKeys: APIKeyStore) {
        self.dictation = dictation
        self.modes = modes
        self.preferences = preferences
        self.usage = usage
        self.permissions = permissions
        self.apiKeys = apiKeys
        super.init()

        statusItem.button?.image = StatusIcon.idle
        statusItem.button?.setAccessibilityTitle("Murmur")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: State

    func phaseChanged(_ phase: DictationController.Phase) {
        animationTimer?.invalidate()
        animationTimer = nil
        switch phase {
        case .idle:
            statusItem.button?.image = StatusIcon.idle
        case .recording:
            levels = Array(repeating: 0, count: 5)
            statusItem.button?.image = StatusIcon.listening(levels: levels)
        case .processing:
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.animationPhase += 0.55
                    self.statusItem.button?.image = StatusIcon.processing(phase: self.animationPhase)
                }
            }
            statusItem.button?.image = StatusIcon.processing(phase: animationPhase)
        }
    }

    func levelChanged(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        statusItem.button?.image = StatusIcon.listening(levels: levels)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        permissions.refresh()

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        for item in setupItems() { menu.addItem(item) }

        let dictate = ClosureMenuItem(title: dictation.isRecording ? "Finish Dictation" : "Start Dictation") { [weak self] in
            self?.dictation.toggle()
        }
        dictate.image = NSImage(systemSymbolName: dictation.isRecording ? "stop.circle" : "mic", accessibilityDescription: nil)
        if let shortcut = preferences.shortcut, let equivalent = shortcut.menuKeyEquivalent {
            dictate.keyEquivalent = equivalent.key
            dictate.keyEquivalentModifierMask = equivalent.modifiers
        }
        menu.addItem(dictate)
        if dictation.isRecording {
            let cancel = ClosureMenuItem(title: "Cancel Dictation") { [weak self] in self?.dictation.cancel() }
            cancel.keyEquivalent = "\u{1B}"
            cancel.keyEquivalentModifierMask = []
            menu.addItem(cancel)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Mode"))
        let activeID = modes.resolve(preferences.activeModeID).id
        for (index, mode) in modes.enabledModes.enumerated() {
            let item = ClosureMenuItem(title: mode.name) { [weak self] in
                self?.preferences.activeModeID = mode.id
            }
            item.state = mode.id == activeID ? .on : .off
            if index < 9 {
                item.keyEquivalent = String(index + 1)
                item.keyEquivalentModifierMask = .command
            }
            if mode.transformsText {
                item.toolTip = mode.prompt
            }
            menu.addItem(item)
        }
        menu.addItem(ClosureMenuItem(title: "Edit Modes…") { [weak self] in self?.openSettings?(.modes) })

        if let result = dictation.lastResult {
            menu.addItem(.separator())
            let copy = ClosureMenuItem(title: "Copy Last Dictation") { Clipboard.write(result.finalText, transient: false) }
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(copy)
            if result.finalText != result.transcript {
                // Hold ⌥ to reveal the raw transcription.
                let original = ClosureMenuItem(title: "Copy Original Transcription") { Clipboard.write(result.transcript, transient: false) }
                original.image = copy.image
                original.isAlternate = true
                original.keyEquivalentModifierMask = .option
                menu.addItem(original)
            }
        }
        if dictation.hasFailedRecording {
            if dictation.lastResult == nil { menu.addItem(.separator()) }
            let retry = ClosureMenuItem(title: "Retry Failed Dictation") { [weak self] in self?.dictation.retryFailedRecording() }
            retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            menu.addItem(retry)
        }

        menu.addItem(.separator())
        let today = usage.today
        let usageItem = ClosureMenuItem(title: "Today: \(Self.minutes(today.minutes)) · ~\(Self.cost(today.totalCost))") { [weak self] in
            self?.openSettings?(.usage)
        }
        usageItem.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil)
        usageItem.toolTip = "Local estimate. Your OpenAI billing dashboard is authoritative."
        menu.addItem(usageItem)

        menu.addItem(.separator())
        let settings = ClosureMenuItem(title: "Settings…") { [weak self] in self?.openSettings?(nil) }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = ClosureMenuItem(title: "Quit Murmur") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var statusTitle: String {
        switch dictation.phase {
        case .recording: "Listening… — Esc to cancel"
        case .processing: dictation.processingLabel
        case .idle: "Murmur — \(modes.resolve(preferences.activeModeID).name) Mode"
        }
    }

    private func setupItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func warning(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Setup needed")
            items.append(item)
        }
        if !apiKeys.hasKey {
            warning("Add OpenAI API Key…") { [weak self] in self?.openSettings?(.openAI) }
        }
        if !permissions.microphoneGranted {
            warning("Allow Microphone Access…") { [weak self] in self?.openSettings?(.general) }
        }
        if !permissions.accessibility {
            warning("Allow Accessibility Access…") { [weak self] in self?.openSettings?(.general) }
        }
        if !items.isEmpty { items.append(.separator()) }
        return items
    }

    static func minutes(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f min", value) : String(format: "%.0f min", value)
    }

    static func cost(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "<$0.01" : String(format: "$%.2f", value)
    }
}

/// NSMenuItem with a closure action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
