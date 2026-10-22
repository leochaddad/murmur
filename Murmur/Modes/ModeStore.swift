import Foundation
import Observation

/// Persists Modes as JSON in ~/Library/Application Support/Murmur/Modes.json.
/// The Default Mode always exists and always comes first.
@MainActor
@Observable
final class ModeStore {
    private(set) var modes: [Mode] = []

    /// Called after any change, e.g. to re-register Mode shortcuts.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("Modes.json"), exampleModel: String = ModelCatalog.recommendedTextModel) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Mode].self, from: data) {
            modes = Self.normalized(saved)
        } else {
            modes = [.default] + Mode.examples(model: exampleModel)
            save()
        }
    }

    var customModes: [Mode] { modes.filter { !$0.isDefault } }
    var enabledModes: [Mode] { modes.filter { $0.isDefault || $0.isEnabled } }

    func mode(withID id: UUID?) -> Mode? {
        guard let id else { return nil }
        return modes.first { $0.id == id }
    }

    /// Resolves the Mode to use for a dictation, falling back to Default when a Mode was
    /// deleted or disabled.
    func resolve(_ id: UUID?) -> Mode {
        guard let mode = mode(withID: id), mode.isDefault || mode.isEnabled else { return modes[0] }
        return mode
    }

    @discardableResult
    func add(model: String) -> Mode {
        var name = "New Mode"
        var counter = 2
        while modes.contains(where: { $0.name == name }) {
            name = "New Mode \(counter)"
            counter += 1
        }
        let mode = Mode(name: name, model: model)
        modes.append(mode)
        changed()
        return mode
    }

    func update(_ mode: Mode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var mode = mode
        if mode.isDefault {
            // The Default Mode only has a shortcut; its name and behavior are fixed.
            mode = Mode(id: Mode.defaultID, name: Mode.default.name, shortcut: mode.shortcut)
        }
        guard modes[index] != mode else { return }
        modes[index] = mode
        changed()
    }

    func delete(_ id: UUID) {
        guard id != Mode.defaultID else { return }
        modes.removeAll { $0.id == id }
        changed()
    }

    /// Reorders custom Modes. Offsets are relative to `customModes`.
    func moveCustomModes(fromOffsets source: IndexSet, toOffset destination: Int) {
        var custom = customModes
        custom.move(fromOffsets: source, toOffset: destination)
        modes = [modes[0]] + custom
        changed()
    }

    private func changed() {
        onChange?()
        scheduleSave()
    }

    /// Typing in the prompt editor changes the Mode on every keystroke; coalesce disk writes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(modes).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Saving modes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func normalized(_ saved: [Mode]) -> [Mode] {
        let custom = saved.filter { !$0.isDefault }
        let defaultMode = saved.first(where: \.isDefault).map {
            Mode(id: Mode.defaultID, name: Mode.default.name, shortcut: $0.shortcut)
        } ?? .default
        return [defaultMode] + custom
    }
}

enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Recordings live here only until they are transcribed. The folder is wiped at launch,
    /// so nothing accumulates even after a crash.
    static let recordingsDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func purgeRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
