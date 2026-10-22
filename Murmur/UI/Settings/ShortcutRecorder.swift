import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    /// Posted while a shortcut field is recording, so global shortcuts can be paused.
    static let shortcutRecordingDidBegin = Notification.Name("MurmurShortcutRecordingDidBegin")
    static let shortcutRecordingDidEnd = Notification.Name("MurmurShortcutRecordingDidEnd")
}

/// Click, then press a key combination — or press and release Fn or a right-hand modifier
/// on its own. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var allowsModifierOnly = true
    /// Returns a message when the shortcut is already used elsewhere in Murmur.
    var conflict: (Shortcut) -> String? = { _ in nil }

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: { isRecording ? stopRecording() : startRecording() }) {
                    Text(label)
                        .foregroundStyle(isRecording || shortcut == nil ? .secondary : .primary)
                        .frame(minWidth: 130)
                }
                .help(isRecording ? "Press a shortcut. Esc cancels, Delete clears." : "Click to record a shortcut")
                if shortcut != nil, !isRecording {
                    Button {
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return allowsModifierOnly ? "Type shortcut or tap a key…" : "Type shortcut…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    private func startRecording() {
        problem = nil
        pendingModifier = nil
        isRecording = true
        NotificationCenter.default.post(name: .shortcutRecordingDidBegin, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutRecordingDidEnd, object: nil)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            pendingModifier = nil
            let modifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
            if modifiers.isEmpty, Int(event.keyCode) == kVK_Escape {
                stopRecording()
                return
            }
            if modifiers.isEmpty, [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                shortcut = nil
                stopRecording()
                return
            }
            accept(Shortcut(keyCode: event.keyCode, modifiers: modifiers))

        case .flagsChanged:
            guard allowsModifierOnly else { return }
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if Shortcut.supportedModifierKeys.contains(event.keyCode),
               ModifierKeyMonitor.isPressed(event.keyCode, in: event.modifierFlags),
               ModifierKeyMonitor.isOnlyModifier(event.keyCode, in: event.modifierFlags) {
                pendingModifier = event.keyCode
            } else if held.isEmpty, let key = pendingModifier {
                // Pressed and released on its own → a modifier-only shortcut.
                accept(.modifierKey(key))
            } else if pendingModifier != nil, event.keyCode != pendingModifier {
                pendingModifier = nil
            }

        default:
            break
        }
    }

    private func accept(_ candidate: Shortcut) {
        if let message = candidate.validationError ?? conflict(candidate) {
            problem = message
            NSSound.beep()
            return
        }
        problem = nil
        shortcut = candidate
        stopRecording()
    }
}
