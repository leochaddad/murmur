import AppKit
import SwiftUI

/// Creates Murmur's components and wires them together.
@MainActor
final class AppController {
    let preferences = Preferences()
    let apiKeys = APIKeyStore()
    let permissions = Permissions()
    let usage = UsageStore()
    let catalog = ModelCatalog()
    let modes: ModeStore
    let dictation: DictationController
    let hotkeys = HotkeyCenter()

    private var hud: HUDController!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController!
    private var observers: [NSObjectProtocol] = []

    init() {
        modes = ModeStore()
        dictation = DictationController(preferences: preferences, modes: modes, apiKeys: apiKeys, usage: usage, permissions: permissions)
    }

    func start() {
        AppPaths.purgeRecordings()
        NSApp.mainMenu = MainMenu.make()

        hud = HUDController(dictation: dictation, modes: modes, preferences: preferences)
        statusItem = StatusItemController(
            dictation: dictation, modes: modes, preferences: preferences,
            usage: usage, permissions: permissions, apiKeys: apiKeys
        )
        settings = SettingsWindowController { [unowned self] tab in self.settingsView(for: tab) }

        dictation.hud = hud
        dictation.hotkeys = hotkeys
        dictation.openSettings = { [weak self] tab in self?.showSettings(tab) }
        dictation.onPhaseChange = { [weak self] phase in self?.statusItem.phaseChanged(phase) }
        dictation.onLevel = { [weak self] level in self?.statusItem.levelChanged(level) }
        statusItem.openSettings = { [weak self] tab in self?.showSettings(tab) }

        hotkeys.handler = { [weak self] action, event, shortcut in
            guard let self else { return }
            switch action {
            case .cancel:
                self.dictation.cancel()
            case .dictate(let modeID):
                self.dictation.handleTrigger(event, modeID: modeID, shortcut: shortcut)
            }
        }
        registerShortcuts()
        observeChanges()

        AudioDevices.observeChanges {
            NotificationCenter.default.post(name: .audioDevicesChanged, object: nil)
        }

        Task { await catalog.refresh(apiKey: apiKeys.key) }

        if !apiKeys.hasKey || !permissions.allGranted {
            showSettings(.general)
        }
    }

    func showSettings(_ tab: SettingsTab?) {
        settings.show(tab)
    }

    /// The main shortcut dictates with the active Mode; each Mode's own shortcut dictates with that Mode.
    private func registerShortcuts() {
        var bindings: [HotkeyCenter.Binding] = []
        if let shortcut = preferences.shortcut {
            bindings.append(.init(shortcut: shortcut, action: .dictate(modeID: nil)))
        }
        for mode in modes.modes where mode.isDefault || mode.isEnabled {
            if let shortcut = mode.shortcut, shortcut != preferences.shortcut {
                bindings.append(.init(shortcut: shortcut, action: .dictate(modeID: mode.id)))
            }
        }
        hotkeys.setBindings(bindings)
    }

    private func observeChanges() {
        modes.onChange = { [weak self] in self?.registerShortcuts() }
        trackPreference { [weak self] in _ = self?.preferences.shortcut }
        // Modifier-key shortcuts only work once Accessibility is granted.
        permissions.onAccessibilityChange = { [weak self] _ in self?.hotkeys.reload() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .shortcutRecordingDidBegin, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeys.suspend() }
        })
        observers.append(center.addObserver(forName: .shortcutRecordingDidEnd, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeys.resume() }
        })
    }

    /// Re-registers shortcuts whenever the dictation shortcut preference changes.
    private func trackPreference(_ read: @escaping () -> Void) {
        withObservationTracking(read) {
            Task { @MainActor [weak self] in
                self?.registerShortcuts()
                self?.trackPreference(read)
            }
        }
    }

    func shutdown() {
        dictation.cancel()
        dictation.discardFailedRecording()
        modes.save()
        AppPaths.purgeRecordings()
    }

    @ViewBuilder
    private func settingsContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .dictation: DictationSettingsView()
        case .modes: ModesSettingsView()
        case .audio: AudioSettingsView()
        case .openAI: OpenAISettingsView()
        case .usage: UsageSettingsView()
        }
    }

    private func settingsView(for tab: SettingsTab) -> AnyView {
        AnyView(
            settingsContent(for: tab)
                .environment(preferences)
                .environment(apiKeys)
                .environment(permissions)
                .environment(usage)
                .environment(catalog)
                .environment(modes)
                .environment(dictation)
        )
    }
}
