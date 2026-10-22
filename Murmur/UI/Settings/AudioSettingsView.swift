import Observation
import SwiftUI

extension Notification.Name {
    static let audioDevicesChanged = Notification.Name("MurmurAudioDevicesChanged")
}

struct AudioSettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(Permissions.self) private var permissions
    @State private var devices = AudioDevices.inputDevices()
    @State private var defaultDevice = AudioDevices.defaultInputDevice()
    @State private var meter = MicrophoneMeter()

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Microphone", selection: $preferences.inputDeviceUID) {
                    Text("System Default" + (defaultDevice.map { " (\($0.name))" } ?? "")).tag(String?.none)
                    Divider()
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if let uid = preferences.inputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                        Text("Unavailable — using System Default").tag(Optional(uid))
                    }
                }
                .onChange(of: preferences.inputDeviceUID) { _, _ in
                    if meter.isRunning { meter.start(deviceUID: preferences.inputDeviceUID) }
                }

                LabeledContent("Input level") {
                    HStack(spacing: 10) {
                        LevelMeter(level: meter.level)
                            .frame(width: 180, height: 6)
                        Button(meter.isRunning ? "Stop" : "Test") {
                            meter.isRunning ? meter.stop() : meter.start(deviceUID: preferences.inputDeviceUID)
                        }
                        .disabled(!permissions.microphoneGranted)
                    }
                }
                if let error = meter.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Input")
            } footer: {
                SettingsFootnote("If the selected microphone is unplugged, Murmur uses the system default. Bluetooth headsets switch to a lower-quality mode while their microphone is in use and can take a moment to start.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in
            devices = AudioDevices.inputDevices()
            defaultDevice = AudioDevices.defaultInputDevice()
        }
        .onDisappear { meter.stop() }
    }
}

/// Live microphone level for the "Test" button. Nothing is written to disk.
@MainActor
@Observable
final class MicrophoneMeter {
    private(set) var level: Float = 0
    private(set) var isRunning = false
    private(set) var error: String?

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var timeout: Timer?

    init() {
        recorder.onLevel = { [weak self] level in self?.level = level }
    }

    func start(deviceUID: String?) {
        stop()
        do {
            try recorder.start(deviceUID: deviceUID, writeToFile: false)
            isRunning = true
            error = nil
            timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        timeout?.invalidate()
        recorder.cancel()
        isRunning = false
        level = 0
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}
