import SwiftUI

struct GeneralSettingsView: View {
    @Environment(Permissions.self) private var permissions
    @Environment(APIKeyStore.self) private var apiKeys
    @Environment(Preferences.self) private var preferences
    @Environment(\.settingsNavigator) private var navigator
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                SetupRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Records your voice while you dictate.",
                    isDone: permissions.microphoneGranted,
                    actionTitle: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings…"
                ) {
                    Task { await permissions.requestMicrophone() }
                }
                SetupRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Lets Murmur paste into the app you’re typing in, and use Fn or a single modifier key as a shortcut. Murmur doesn’t read your screen or keystrokes.",
                    isDone: permissions.accessibility,
                    actionTitle: "Allow…"
                ) {
                    permissions.requestAccessibility()
                }
                SetupRow(
                    symbol: "key.fill",
                    title: "OpenAI API key",
                    detail: "Murmur sends audio directly to OpenAI using your own key.",
                    isDone: apiKeys.hasKey,
                    actionTitle: "Add Key…"
                ) {
                    navigator.open(.openAI)
                }
            } header: {
                Text("Setup")
            } footer: {
                if permissions.allGranted && apiKeys.hasKey, let shortcut = preferences.shortcut {
                    Text("You’re all set. Put your cursor anywhere and press \(shortcut.displayString) to dictate.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Launch Murmur at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LaunchAtLogin.setEnabled(newValue)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                Toggle("Play sounds when recording starts and stops", isOn: $preferences.playSounds)
                Toggle("Show the floating indicator while dictating", isOn: $preferences.showOverlay)
            }

            Section {
                Label {
                    Text("Audio is recorded on this Mac, sent directly to OpenAI, and deleted right after it’s transcribed. Your API key stays in the macOS Keychain. Modes, settings and usage statistics are stored locally. There is no Murmur server and no analytics.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                }
                .font(.callout)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            permissions.refresh()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

private struct SetupRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isDone: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(isDone ? Color.green : Color.orange, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isDone {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button(actionTitle, action: action)
            }
        }
        .padding(.vertical, 2)
    }
}
