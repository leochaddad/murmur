import Foundation

/// Spoken-language hint for transcription. Leaving it on Automatic lets the model detect
/// the language (and handle mixed-language speech); pinning one improves accuracy for short clips.
struct SpokenLanguage: Identifiable, Hashable {
    let code: String
    var id: String { code }

    var name: String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    static let all: [SpokenLanguage] = [
        "en", "pt", "es", "fr", "de", "it", "nl", "sv", "da", "no", "fi", "pl", "cs", "uk", "ru",
        "tr", "el", "he", "ar", "hi", "ja", "ko", "zh", "id", "vi", "th", "ca", "ro", "hu",
    ]
    .map(SpokenLanguage.init(code:))
    .sorted { $0.name < $1.name }
}
