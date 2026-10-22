import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// Tracks the two privacy permissions Murmur needs:
/// - Microphone, to record dictation.
/// - Accessibility, to paste the result into the app you are typing in
///   (and to observe modifier-only shortcuts such as Fn).
@MainActor
@Observable
final class Permissions {
    private(set) var microphone: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibility: Bool = AXIsProcessTrusted()

    /// Called when the Accessibility grant changes, so modifier-key monitors can be reinstalled.
    @ObservationIgnored var onAccessibilityChange: ((Bool) -> Void)?
    @ObservationIgnored private var pollTimer: Timer?

    var microphoneGranted: Bool { microphone == .authorized }
    var allGranted: Bool { microphoneGranted && accessibility }

    init() {
        startPollingIfNeeded()
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility {
            accessibility = trusted
            onAccessibilityChange?(trusted)
        }
        startPollingIfNeeded()
    }

    func requestMicrophone() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        case .denied, .restricted:
            openPrivacyPane("Privacy_Microphone")
        default:
            refresh()
        }
    }

    /// The first time, shows the system prompt — it also adds Murmur to the Accessibility list —
    /// which offers to open System Settings. Afterwards, opens the pane directly.
    func requestAccessibility() {
        let promptedKey = "accessibilityPromptShown"
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted, UserDefaults.standard.bool(forKey: promptedKey) {
            openPrivacyPane("Privacy_Accessibility")
        }
        UserDefaults.standard.set(true, forKey: promptedKey)
        startPollingIfNeeded()
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// There is no notification for Accessibility changes, so poll (cheaply) until everything is granted.
    private func startPollingIfNeeded() {
        guard !allGranted else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
