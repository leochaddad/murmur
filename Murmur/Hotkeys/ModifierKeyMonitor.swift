import AppKit
import Carbon.HIToolbox

/// Watches a single modifier key (Fn, Right ⌥, Right ⌘ …) so it can act as a push-to-talk or
/// toggle trigger. Uses NSEvent monitors, which only receive keyboard events from other apps
/// when Murmur has Accessibility access, and which don't see keys typed into secure fields.
///
/// If any other key or modifier is used while the trigger is held, the press was part of a
/// chord (e.g. Right ⌥ + E for "é"), so `.interrupt` is sent and the release is ignored.
@MainActor
final class ModifierKeyMonitor {
    private let keyCode: UInt16
    private let onEvent: (TriggerEvent) -> Void
    private var monitors: [Any] = []
    private var isDown = false
    private var isChord = false

    init(keyCode: UInt16, onEvent: @escaping (TriggerEvent) -> Void) {
        self.keyCode = keyCode
        self.onEvent = onEvent

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func invalidate() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == keyCode:
            let down = Self.isPressed(keyCode, in: event.modifierFlags)
            if down, !isDown {
                isDown = true
                isChord = !Self.isOnlyModifier(keyCode, in: event.modifierFlags)
                if !isChord { onEvent(.press) }
            } else if !down, isDown {
                isDown = false
                if !isChord { onEvent(.release) }
            }
        case .flagsChanged, .keyDown:
            if isDown, !isChord {
                isChord = true
                onEvent(.interrupt)
            }
        default:
            break
        }
    }

    /// Device-dependent bits from IOLLEvent.h, so left and right modifiers can be told apart.
    nonisolated static func isPressed(_ keyCode: UInt16, in flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch Int(keyCode) {
        case kVK_Function: return flags.contains(.function)
        case kVK_RightCommand: return raw & 0x10 != 0
        case kVK_Command: return raw & 0x08 != 0
        case kVK_RightOption: return raw & 0x40 != 0
        case kVK_Option: return raw & 0x20 != 0
        case kVK_RightControl: return raw & 0x2000 != 0
        case kVK_Control: return raw & 0x01 != 0
        case kVK_RightShift: return raw & 0x04 != 0
        case kVK_Shift: return raw & 0x02 != 0
        default: return false
        }
    }

    nonisolated static func isOnlyModifier(_ keyCode: UInt16, in flags: NSEvent.ModifierFlags) -> Bool {
        let own: NSEvent.ModifierFlags
        switch Int(keyCode) {
        case kVK_Function: own = .function
        case kVK_RightCommand, kVK_Command: own = .command
        case kVK_RightOption, kVK_Option: own = .option
        case kVK_RightControl, kVK_Control: own = .control
        case kVK_RightShift, kVK_Shift: own = .shift
        default: own = []
        }
        let others = flags.intersection([.command, .option, .control, .shift, .function]).subtracting(own)
        return others.isEmpty
    }
}
