import Carbon.HIToolbox
import SwiftUI

struct DictationSettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(Permissions.self) private var permissions
    @Environment(ModeStore.self) private var modes

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                LabeledContent("Dictation shortcut") {
                    ShortcutRecorder(shortcut: $preferences.shortcut, conflict: conflict)
                }
                Picker("Shortcut behavior", selection: $preferences.triggerBehavior) {
                    ForEach(TriggerBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                if preferences.shortcut?.isModifierOnly == true && !permissions.accessibility {
                    Label("Single-key shortcuts need Accessibility access (General tab).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if preferences.shortcut?.keyCode == UInt16(kVK_Function) && preferences.shortcut?.isModifierOnly == true {
                    Label("Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”, and change the macOS Dictation shortcut, so Fn only triggers Murmur.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                SettingsFootnote("Works in every app. Press Esc while recording to cancel. Modes can also have their own shortcuts.")
            }

            Section {
                Picker("Spoken language", selection: $preferences.language) {
                    Text("Detect automatically").tag("")
                    Divider()
                    ForEach(SpokenLanguage.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vocabulary")
                    TextField("Vocabulary", text: $preferences.vocabulary, prompt: Text("Claude Code, SwiftUI, Kubernetes, Ana Beatriz…"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                }
            } header: {
                Text("Transcription")
            } footer: {
                SettingsFootnote("Automatic detection handles switching between languages. Vocabulary helps the model spell names, jargon and product terms — separate them with commas.")
            }

            Section {
                Toggle("Paste the result where the cursor is", isOn: $preferences.autoInsert)
                Toggle("Restore the clipboard after pasting", isOn: $preferences.restoreClipboard)
                    .disabled(!preferences.autoInsert)
            } header: {
                Text("Inserting Text")
            } footer: {
                SettingsFootnote("When pasting is off, the result is copied to the clipboard instead. The last result is always available from the menu bar.")
            }

            Section {
                Text("macOS reserves the 🎤 key and its own Dictation shortcut — apps can’t take them over. For one-key dictation, record Fn 🌐 or a right-hand modifier such as Right ⌥ as Murmur’s shortcut and hold it while you talk. Quick taps are ignored, so tapping Fn still opens the emoji picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Replacing macOS Dictation")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func conflict(_ shortcut: Shortcut) -> String? {
        modes.modes.first { $0.shortcut == shortcut }.map { "Already used by the “\($0.name)” Mode." }
    }
}
