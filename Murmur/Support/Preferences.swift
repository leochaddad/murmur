import Foundation
import Observation

/// How the dictation shortcut behaves.
enum TriggerBehavior: String, CaseIterable, Identifiable, Codable {
    /// Hold the shortcut to talk, or tap it once to start and again to stop.
    case automatic
    /// Press once to start, press again to finish.
    case toggle
    /// Record only while the shortcut is held down.
    case pushToTalk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Hold to talk, or tap to toggle"
        case .toggle: "Toggle (press to start and to stop)"
        case .pushToTalk: "Push to talk (hold while speaking)"
        }
    }
}

/// User preferences, persisted in UserDefaults. Modes and usage live in their own stores.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var shortcut: Shortcut? { didSet { store(shortcut, Keys.shortcut) } }
    var triggerBehavior: TriggerBehavior { didSet { defaults.set(triggerBehavior.rawValue, forKey: Keys.triggerBehavior) } }
    var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: Keys.transcriptionModel) } }
    /// ISO-639-1 code, or empty for automatic detection.
    var language: String { didSet { defaults.set(language, forKey: Keys.language) } }
    /// Names, jargon and product terms that the transcription model should recognize.
    var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Keys.vocabulary) } }
    /// Core Audio device UID, or nil for the system default input.
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) } }
    var autoInsert: Bool { didSet { defaults.set(autoInsert, forKey: Keys.autoInsert) } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Keys.playSounds) } }
    var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: Keys.showOverlay) } }
    var activeModeID: UUID { didSet { defaults.set(activeModeID.uuidString, forKey: Keys.activeModeID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.triggerBehavior: TriggerBehavior.automatic.rawValue,
            Keys.transcriptionModel: "gpt-transcribe",
            Keys.autoInsert: true,
            Keys.restoreClipboard: true,
            Keys.playSounds: true,
            Keys.showOverlay: true,
        ])

        let isFirstLaunch = defaults.object(forKey: Keys.shortcut) == nil
        shortcut = isFirstLaunch ? .defaultDictation : Self.load(Shortcut.self, Keys.shortcut, from: defaults)
        triggerBehavior = TriggerBehavior(rawValue: defaults.string(forKey: Keys.triggerBehavior) ?? "") ?? .automatic
        transcriptionModel = defaults.string(forKey: Keys.transcriptionModel) ?? "gpt-transcribe"
        language = defaults.string(forKey: Keys.language) ?? ""
        vocabulary = defaults.string(forKey: Keys.vocabulary) ?? ""
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        autoInsert = defaults.bool(forKey: Keys.autoInsert)
        restoreClipboard = defaults.bool(forKey: Keys.restoreClipboard)
        playSounds = defaults.bool(forKey: Keys.playSounds)
        showOverlay = defaults.bool(forKey: Keys.showOverlay)
        activeModeID = defaults.string(forKey: Keys.activeModeID).flatMap(UUID.init(uuidString:)) ?? Mode.defaultID

        if isFirstLaunch { store(shortcut, Keys.shortcut) }
    }

    /// Vocabulary terms split on commas and new lines.
    var vocabularyTerms: [String] {
        vocabulary
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func store<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            // Keep an explicit "no shortcut" marker so the default isn't re-applied on next launch.
            defaults.set(Data(), forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Keys {
        static let shortcut = "dictationShortcut"
        static let triggerBehavior = "triggerBehavior"
        static let transcriptionModel = "transcriptionModel"
        static let language = "language"
        static let vocabulary = "vocabulary"
        static let inputDeviceUID = "inputDeviceUID"
        static let autoInsert = "autoInsert"
        static let restoreClipboard = "restoreClipboard"
        static let playSounds = "playSounds"
        static let showOverlay = "showOverlay"
        static let activeModeID = "activeModeID"
    }
}
