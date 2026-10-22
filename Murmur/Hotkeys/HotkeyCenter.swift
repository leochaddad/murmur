import AppKit
import Carbon.HIToolbox

enum TriggerEvent {
    case press
    case release
    /// A modifier-only trigger was used as part of a chord (e.g. Right ⌥ + E), so it wasn't meant for Murmur.
    case interrupt
}

/// Registers Murmur's global shortcuts.
///
/// Key combinations use Carbon's `RegisterEventHotKey`: it is still the supported way to get
/// system-wide hot keys on macOS, needs no permission, delivers both press and release
/// (for push-to-talk), and swallows the keystroke so it never reaches the focused app.
/// Modifier-only triggers (Fn, Right ⌥ …) can't be registered that way, so they are observed
/// with `ModifierKeyMonitor`, which requires Accessibility access.
@MainActor
final class HotkeyCenter {
    enum Action: Hashable {
        /// Dictate with the given Mode, or with the active Mode when nil.
        case dictate(modeID: UUID?)
        case cancel
    }

    struct Binding {
        let shortcut: Shortcut
        let action: Action
    }

    var handler: ((Action, TriggerEvent, Shortcut) -> Void)?

    /// Shortcuts that couldn't be registered (typically taken by another app or disallowed by macOS).
    private(set) var failedShortcuts: [Shortcut] = []

    private var bindings: [Binding] = []
    private var registered: [UInt32: (ref: EventHotKeyRef, binding: Binding)] = [:]
    private var pressedIDs: Set<UInt32> = []
    private var lastReleaseTime: [UInt32: TimeInterval] = [:]
    private var modifierMonitors: [ModifierKeyMonitor] = []
    private var escapeRegistration: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var isSuspended = false

    private static let signature: OSType = 0x4D_52_4D_52 // 'MRMR'
    private static let escapeID: UInt32 = 0xFFFF
    private static let bounceInterval: TimeInterval = 0.12

    init() {
        installCarbonHandler()
    }

    func setBindings(_ bindings: [Binding]) {
        self.bindings = bindings
        reload()
    }

    /// Temporarily disables every shortcut, e.g. while the user records a new one.
    func suspend() {
        isSuspended = true
        reload()
    }

    func resume() {
        isSuspended = false
        reload()
    }

    /// Re-creates modifier monitors, e.g. after Accessibility access was granted.
    func reload() {
        unregisterAll()
        guard !isSuspended else { return }

        for binding in bindings {
            if binding.shortcut.isModifierOnly {
                let monitor = ModifierKeyMonitor(keyCode: binding.shortcut.keyCode) { [weak self] event in
                    self?.handler?(binding.action, event, binding.shortcut)
                }
                modifierMonitors.append(monitor)
            } else {
                register(binding)
            }
        }
    }

    /// While recording, Esc cancels. It is only registered for that window of time so
    /// Esc keeps working normally in every other situation.
    func setEscapeCancelsRecording(_ enabled: Bool) {
        if enabled, escapeRegistration == nil, !isSuspended {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: Self.escapeID)
            if RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetEventDispatcherTarget(), 0, &ref) == noErr {
                escapeRegistration = ref
            }
        } else if !enabled, let ref = escapeRegistration {
            UnregisterEventHotKey(ref)
            escapeRegistration = nil
        }
    }

    // MARK: Carbon

    private func register(_ binding: Binding) {
        let shortcut = binding.shortcut
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref
        )
        if status == noErr, let ref {
            registered[id] = (ref, binding)
        } else {
            failedShortcuts.append(shortcut)
            Log.hotkeys.error("Could not register \(shortcut.displayString, privacy: .public): \(status)")
        }
    }

    private func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
        pressedIDs.removeAll()
        lastReleaseTime.removeAll()
        failedShortcuts.removeAll()
        modifierMonitors.forEach { $0.invalidate() }
        modifierMonitors.removeAll()
    }

    private func installCarbonHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                center.handleCarbon(id: hotKeyID.id, isPress: isPress)
            }
            return noErr
        }, eventTypes.count, &eventTypes, context, &eventHandler)
    }

    private func handleCarbon(id: UInt32, isPress: Bool) {
        if id == Self.escapeID {
            if isPress { handler?(.cancel, .press, Shortcut(keyCode: UInt16(kVK_Escape), modifiers: [])) }
            return
        }
        guard let entry = registered[id] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isPress {
            // A press arriving a few milliseconds after a release isn't a person pressing again:
            // macOS sometimes re-reports the hot key while the modifiers are being let go.
            if let released = lastReleaseTime[id], now - released < Self.bounceInterval { return }
            // Ignore auto-repeat while the key is held.
            guard pressedIDs.insert(id).inserted else { return }
            handler?(entry.binding.action, .press, entry.binding.shortcut)
        } else {
            // Only report releases that pair with a press we reported.
            guard pressedIDs.remove(id) != nil else { return }
            lastReleaseTime[id] = now
            handler?(entry.binding.action, .release, entry.binding.shortcut)
        }
    }
}
