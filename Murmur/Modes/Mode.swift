import Foundation

/// A Mode decides what happens to a transcription before it is inserted.
/// The Default Mode inserts the transcription as-is; every other Mode sends it to an
/// OpenAI text model together with the Mode's instructions.
struct Mode: Codable, Identifiable, Hashable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID
    var name: String
    var prompt: String
    var model: String
    var isEnabled: Bool
    /// Optional shortcut that dictates with this Mode without changing the active Mode.
    var shortcut: Shortcut?

    init(id: UUID = UUID(), name: String, prompt: String = "", model: String = "", isEnabled: Bool = true, shortcut: Shortcut? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.model = model
        self.isEnabled = isEnabled
        self.shortcut = shortcut
    }

    var isDefault: Bool { id == Self.defaultID }

    /// Whether dictation in this Mode involves a model call after transcription.
    var transformsText: Bool {
        !isDefault && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let `default` = Mode(id: defaultID, name: "Default")

    /// Starting points created on first launch. They are ordinary Modes — edit or delete them freely.
    static func examples(model: String) -> [Mode] {
        [
            Mode(
                name: "English",
                prompt: "Translate the provided speech transcription into natural English. Preserve its meaning and intent. Return only the translated text.",
                model: model
            ),
            Mode(
                name: "Structure",
                prompt: "Clean up and structure this speech transcription. Remove speech disfluencies and unnecessary repetition while preserving all information and intent. Do not add information that was not present in the original transcription.",
                model: model
            ),
        ]
    }
}
