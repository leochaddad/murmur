import AppKit
import AVFoundation
import Observation

/// Runs the dictation pipeline:
/// shortcut → record → transcribe → (Mode) → insert at the cursor.
///
/// Each finished recording becomes a job. Jobs process concurrently — you can start the next
/// dictation while the previous one is still transcribing — but insert strictly in the order
/// they were recorded.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle, recording, processing
    }

    struct Result {
        let transcript: String
        let finalText: String
        let modeName: String
    }

    private(set) var isRecording = false
    private(set) var pendingJobs = 0
    private(set) var recordingStartedAt: Date?
    private(set) var recordingMode: Mode = .default
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.levelHistory)
    private(set) var processingLabel = "Transcribing…"
    private(set) var lastResult: Result?
    private(set) var hasFailedRecording = false

    var phase: Phase {
        isRecording ? .recording : (pendingJobs > 0 ? .processing : .idle)
    }

    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    @ObservationIgnored var onLevel: ((Float) -> Void)?
    @ObservationIgnored var openSettings: ((SettingsTab) -> Void)?
    @ObservationIgnored weak var hotkeys: HotkeyCenter?
    @ObservationIgnored weak var hud: HUDController?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let modes: ModeStore
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let usage: UsageStore
    @ObservationIgnored private let permissions: Permissions

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var session: TranscriptionSession?
    @ObservationIgnored private var target: NSRunningApplication?
    /// The recording was started with the active Mode rather than a Mode's own shortcut.
    @ObservationIgnored private var recordingFollowsActiveMode = false
    @ObservationIgnored private var lastJob: Task<Void, Never>?
    @ObservationIgnored private var failedRecording: (audio: RecordedAudio, mode: Mode)?
    @ObservationIgnored private var maxDurationTimer: Timer?
    @ObservationIgnored private var lastPhase: Phase = .idle
    /// Keeps App Nap from throttling timers and the indicator while a dictation is in progress.
    @ObservationIgnored private var activity: NSObjectProtocol?

    // Shortcut state.
    @ObservationIgnored private var pressStartedAt: Date?
    @ObservationIgnored private var pressStoppedRecording = false
    /// The microphone is capturing. `isRecording` only becomes true once the recording is
    /// revealed (sound, indicator), which for a held shortcut happens after `revealDelay`.
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var revealTimer: Timer?

    static let levelHistory = 28
    /// A press shorter than this is a tap, not a hold. Recording starts immediately on press but
    /// stays invisible until then, so a quick tap of Fn can still open the emoji picker without
    /// Murmur flashing its indicator, playing a sound or sending anything to OpenAI.
    static let revealDelay: TimeInterval = 0.25
    /// "Hold to talk, or tap to toggle": releasing after this long finishes the recording.
    static let holdThreshold: TimeInterval = 0.4
    /// Recordings shorter than this were almost certainly accidental: they are discarded silently.
    static let minimumDuration: TimeInterval = 1.5
    static let maximumDuration: TimeInterval = 20 * 60
    /// Recordings whose loudest moment is below this (dBFS) contain no speech.
    static let silenceThreshold: Float = -60

    init(preferences: Preferences, modes: ModeStore, apiKeys: APIKeyStore, usage: UsageStore, permissions: Permissions) {
        self.preferences = preferences
        self.modes = modes
        self.apiKeys = apiKeys
        self.usage = usage
        self.permissions = permissions

        recorder.onLevel = { [weak self] level in self?.receive(level: level) }
        recorder.onInterruption = { [weak self] in self?.stop() }
    }

    // MARK: Shortcut handling

    func handleTrigger(_ event: TriggerEvent, modeID: UUID?, shortcut: Shortcut) {
        Log.hotkeys.debug("Trigger \(String(describing: event), privacy: .public) (capturing: \(self.isCapturing))")
        let isModifierKey = shortcut.isModifierOnly
        switch preferences.triggerBehavior {
        case .toggle:
            // A lone modifier acts on release, so chords like Right ⌥ + E never start a recording.
            let fires = isModifierKey ? event == .release : event == .press
            if fires { toggle(modeID: modeID) }

        case .pushToTalk:
            switch event {
            case .press:
                start(modeID: modeID, revealAfterHold: true)
            case .release:
                // Released before the recording was revealed: a tap, not dictation.
                isRecording ? stop() : cancel()
            case .interrupt:
                cancel()
            }

        case .automatic:
            switch event {
            case .press:
                if isCapturing {
                    pressStoppedRecording = true
                    stop()
                } else {
                    pressStoppedRecording = false
                    pressStartedAt = Date()
                    start(modeID: modeID, revealAfterHold: true)
                }
            case .release:
                defer { pressStartedAt = nil }
                guard !pressStoppedRecording, isCapturing, let pressStartedAt else { return }
                if Date().timeIntervalSince(pressStartedAt) >= Self.holdThreshold {
                    stop() // held: push-to-talk
                } else if shortcut.tapBelongsToSystem {
                    cancel() // a tap on Fn opens the emoji picker; leave it to macOS
                } else {
                    reveal() // tapped: keep recording until the next press
                }
            case .interrupt:
                if isCapturing, pressStartedAt != nil { cancel() }
                pressStartedAt = nil
            }
        }
    }

    func toggle(modeID: UUID? = nil) {
        isCapturing ? stop() : start(modeID: modeID)
    }

    // MARK: Recording

    /// Starts capturing audio. With `revealAfterHold`, the recording stays silent and invisible
    /// until the shortcut has been held for `revealDelay`; audio from the very first moment is kept.
    func start(modeID: UUID? = nil, revealAfterHold: Bool = false) {
        guard !isCapturing else { return }
        guard let apiKey = apiKeys.key, !apiKey.isEmpty else {
            showProblem(OpenAIError.missingAPIKey, title: "Add your OpenAI API key", settingsTab: .openAI)
            return
        }
        permissions.refresh()
        switch permissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            Task { await permissions.requestMicrophone() }
            return
        default:
            showMessage(HUDMessage(
                style: .error, title: "Microphone access is off",
                detail: "Allow Murmur under Privacy & Security › Microphone.",
                actions: [HUDAction("Open Settings") { [weak self] in self?.permissions.openPrivacyPane("Privacy_Microphone") }]
            ))
            return
        }

        let mode = modes.resolve(modeID ?? preferences.activeModeID)
        let settings = TranscriptionSettings(
            model: preferences.transcriptionModel,
            language: preferences.language.isEmpty ? nil : preferences.language,
            vocabulary: preferences.vocabularyTerms
        )
        let client = OpenAIClient(apiKey: apiKey)
        let session = FileTranscriptionSession(client: client, settings: settings)
        recorder.onBuffer = { [session] buffer in session.append(buffer) }

        do {
            try recorder.start(deviceUID: preferences.inputDeviceUID)
        } catch {
            Log.audio.error("Recorder failed to start: \(error.localizedDescription, privacy: .public)")
            if preferences.playSounds { SoundEffects.playFailure() }
            showMessage(HUDMessage(style: .error, title: "Couldn’t start recording", detail: error.localizedDescription))
            return
        }

        self.session = session
        isCapturing = true
        target = NSWorkspace.shared.frontmostApplication
        recordingMode = mode
        recordingFollowsActiveMode = modeID == nil
        recordingStartedAt = Date()
        levels = Array(repeating: 0, count: Self.levelHistory)
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Self.maximumDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }

        if revealAfterHold {
            revealTimer = Timer.scheduledTimer(withTimeInterval: Self.revealDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.reveal() }
            }
        } else {
            reveal()
        }
    }

    /// Makes a capturing recording visible: sound, indicator, menu bar state, Esc to cancel.
    private func reveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        guard isCapturing, !isRecording else { return }
        isRecording = true
        hud?.dismissMessage()
        if preferences.playSounds { SoundEffects.playStart() }
        hotkeys?.setEscapeCancelsRecording(true)
        phaseChanged()

        // Open the connection to OpenAI while the user speaks.
        if let key = apiKeys.key {
            let model = preferences.transcriptionModel
            Task.detached(priority: .utility) { await OpenAIClient(apiKey: key).warmUp(model: model) }
        }
    }

    /// Switches the Mode of the recording in progress (the indicator's Mode menu). If the recording
    /// uses the active Mode, the choice becomes the active Mode too, as if picked in the menu bar.
    func switchRecordingMode(to id: UUID) {
        guard isCapturing else { return }
        recordingMode = modes.resolve(id)
        if recordingFollowsActiveMode { preferences.activeModeID = recordingMode.id }
    }

    func stop() {
        guard isCapturing else { return }
        guard isRecording else {
            cancel()
            return
        }
        let audio = recorder.stop()
        let session = self.session
        let mode = recordingMode
        let target = self.target
        endRecording()

        if let audio {
            Log.audio.info("Recording stopped: \(audio.duration, format: .fixed(precision: 2))s, peak \(audio.peakLevel, format: .fixed(precision: 1)) dBFS")
            // Too short to be deliberate: drop it like a cancel — no sound, no indicator, no request.
            guard audio.duration >= Self.minimumDuration else {
                audio.delete()
                return
            }
        }
        if preferences.playSounds { SoundEffects.playStop() }

        guard let audio, let session else {
            showMessage(HUDMessage(style: .error, title: "Recording failed", detail: "No audio was captured."))
            return
        }
        guard audio.peakLevel > Self.silenceThreshold else {
            audio.delete()
            showMessage(HUDMessage(style: .info, title: "No speech detected", detail: "Check the microphone in Murmur Settings › Audio.", duration: 3))
            return
        }
        enqueue(audio: audio, session: session, mode: mode, target: target)
    }

    /// Discards the current recording (Esc, a tap that wasn't meant for Murmur, or a modifier
    /// trigger that turned out to be part of a chord). Nothing is sent anywhere.
    func cancel() {
        guard isCapturing else { return }
        recorder.cancel()
        endRecording()
    }

    private func endRecording() {
        isCapturing = false
        isRecording = false
        revealTimer?.invalidate()
        revealTimer = nil
        session = nil
        target = nil
        recordingStartedAt = nil
        recorder.onBuffer = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        hotkeys?.setEscapeCancelsRecording(false)
        phaseChanged()
    }

    private func receive(level: Float) {
        guard isCapturing else { return }
        levels.removeFirst()
        levels.append(level)
        if isRecording { onLevel?(level) }
    }

    // MARK: Processing

    private func enqueue(audio: RecordedAudio, session: TranscriptionSession, mode: Mode, target: NSRunningApplication?) {
        runJob(target: target) { controller in
            await controller.transcribeAndProcess(audio: audio, session: session, mode: mode)
        }
    }

    /// Runs `work` concurrently with other jobs, then delivers its text after every earlier job has delivered.
    private func runJob(target: NSRunningApplication?, _ work: @escaping (DictationController) async -> String?) {
        pendingJobs += 1
        processingLabel = "Transcribing…"
        phaseChanged()
        let previous = lastJob
        lastJob = Task { [weak self] in
            guard let self else { return }
            let text = await work(self)
            await previous?.value
            if let text { await self.deliver(text, to: target) }
            self.pendingJobs -= 1
            self.phaseChanged()
        }
    }

    /// Returns the text to insert, or nil if there is nothing to insert (errors are reported here).
    private func transcribeAndProcess(audio: RecordedAudio, session: TranscriptionSession, mode: Mode) async -> String? {
        let transcript: Transcript
        do {
            transcript = try await withRetry { try await session.finish(audio: audio) }
        } catch {
            transcriptionFailed(error, audio: audio, mode: mode)
            return nil
        }
        audio.delete()
        usage.recordTranscription(model: transcript.model, audioSeconds: transcript.audioSeconds, billedSeconds: transcript.billedSeconds)
        Log.app.info("Transcribed \(audio.duration, format: .fixed(precision: 1))s with \(transcript.model, privacy: .public)")

        guard !transcript.text.isEmpty else {
            Log.app.info("Transcription was empty")
            showMessage(HUDMessage(style: .info, title: "No speech detected", duration: 2.5))
            return nil
        }
        return await applyMode(mode, to: transcript.text)
    }

    private func applyMode(_ mode: Mode, to transcript: String) async -> String? {
        guard mode.transformsText else {
            lastResult = Result(transcript: transcript, finalText: transcript, modeName: mode.name)
            return transcript
        }
        // Keep the raw transcription recoverable no matter what happens next.
        lastResult = Result(transcript: transcript, finalText: transcript, modeName: mode.name)
        processingLabel = mode.name + "…"
        guard let apiKey = apiKeys.key else {
            modeFailed(OpenAIError.missingAPIKey, transcript: transcript, mode: mode)
            return nil
        }
        do {
            let processor = ModeProcessor(client: OpenAIClient(apiKey: apiKey))
            let output = try await withRetry { try await processor.process(transcript, mode: mode) }
            usage.recordModeProcessing(output)
            lastResult = Result(transcript: transcript, finalText: output.text, modeName: mode.name)
            if output.text.isEmpty {
                showMessage(HUDMessage(style: .info, title: "“\(mode.name)” returned no text", duration: 3))
                return nil
            }
            return output.text
        } catch {
            modeFailed(error, transcript: transcript, mode: mode)
            return nil
        }
    }

    private func deliver(_ text: String, to target: NSRunningApplication?) async {
        guard preferences.autoInsert else {
            Clipboard.write(text, transient: false)
            showMessage(HUDMessage(style: .info, title: "Copied to clipboard", duration: 2))
            return
        }
        let outcome = await TextInserter.insert(text, into: target, restoreClipboard: preferences.restoreClipboard)
        switch outcome {
        case .pasted:
            break
        case .copied(.accessibilityNotGranted):
            showMessage(HUDMessage(
                style: .warning, title: "Copied to clipboard — press ⌘V",
                detail: "Allow Accessibility access so Murmur can paste for you.",
                actions: [HUDAction("Open Settings") { [weak self] in self?.openSettings?(.general) }]
            ))
        case .copied(.targetUnavailable(let appName)):
            showMessage(HUDMessage(style: .warning, title: "Copied to clipboard — press ⌘V", detail: "Couldn’t switch back to \(appName)."))
        }
    }

    // MARK: Failures and recovery

    private func transcriptionFailed(_ error: Error, audio: RecordedAudio, mode: Mode) {
        // Keep this one recording so it can be retried; replace any older failed one.
        failedRecording?.audio.delete()
        failedRecording = (audio, mode)
        hasFailedRecording = true
        if preferences.playSounds { SoundEffects.playFailure() }

        if let error = error as? OpenAIError, [.invalidAPIKey, .missingAPIKey, .insufficientQuota].contains(error) {
            showProblem(error, title: "Transcription failed", settingsTab: .openAI, retry: true)
            return
        }
        showMessage(HUDMessage(
            style: .error, title: "Transcription failed", detail: Self.describe(error),
            actions: [HUDAction("Retry", isPrimary: true) { [weak self] in self?.retryFailedRecording() }],
            duration: 15
        ))
    }

    private func modeFailed(_ error: Error, transcript: String, mode: Mode) {
        if preferences.playSounds { SoundEffects.playFailure() }
        showMessage(HUDMessage(
            style: .error, title: "“\(mode.name)” couldn’t process the text", detail: Self.describe(error),
            actions: [
                HUDAction("Insert Original", isPrimary: true) { [weak self] in self?.insertNow(transcript) },
                HUDAction("Retry") { [weak self] in self?.retryMode(mode, transcript: transcript) },
            ],
            duration: 20
        ))
    }

    /// Re-sends the last recording that failed to transcribe, inserting at the current cursor.
    func retryFailedRecording() {
        guard let failed = failedRecording, let apiKey = apiKeys.key else { return }
        failedRecording = nil
        hasFailedRecording = false
        hud?.dismissMessage()
        let settings = TranscriptionSettings(
            model: preferences.transcriptionModel,
            language: preferences.language.isEmpty ? nil : preferences.language,
            vocabulary: preferences.vocabularyTerms
        )
        let session = FileTranscriptionSession(client: OpenAIClient(apiKey: apiKey), settings: settings)
        enqueue(audio: failed.audio, session: session, mode: failed.mode, target: NSWorkspace.shared.frontmostApplication)
    }

    func discardFailedRecording() {
        failedRecording?.audio.delete()
        failedRecording = nil
        hasFailedRecording = false
    }

    private func retryMode(_ mode: Mode, transcript: String) {
        hud?.dismissMessage()
        runJob(target: NSWorkspace.shared.frontmostApplication) { controller in
            await controller.applyMode(mode, to: transcript)
        }
    }

    /// Inserts text at the current cursor (HUD and menu actions).
    func insertNow(_ text: String) {
        hud?.dismissMessage()
        runJob(target: NSWorkspace.shared.frontmostApplication) { _ in text }
    }

    // MARK: Helpers

    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as OpenAIError where error.isTransient {
            Log.openAI.notice("Transient error, retrying once: \(error.shortDescription, privacy: .public)")
            try? await Task.sleep(for: .milliseconds(600))
            return try await operation()
        }
    }

    private func showProblem(_ error: OpenAIError, title: String, settingsTab: SettingsTab, retry: Bool = false) {
        var actions = [HUDAction("Open Settings", isPrimary: true) { [weak self] in self?.openSettings?(settingsTab) }]
        if retry { actions.append(HUDAction("Retry") { [weak self] in self?.retryFailedRecording() }) }
        showMessage(HUDMessage(style: .error, title: title, detail: error.errorDescription, actions: actions, duration: 15))
    }

    private func showMessage(_ message: HUDMessage) {
        hud?.show(message)
    }

    private static func describe(_ error: Error) -> String {
        (error as? OpenAIError)?.errorDescription ?? error.localizedDescription
    }

    private func phaseChanged() {
        let phase = phase
        hud?.update()
        guard phase != lastPhase else { return }
        lastPhase = phase
        if phase == .idle, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        } else if phase != .idle, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Dictation")
        }
        onPhaseChange?(phase)
    }
}
