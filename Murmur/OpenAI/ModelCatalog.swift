import Foundation
import Observation

/// Discovers which OpenAI models the user's key can use, for the transcription and Mode
/// model pickers. The list is cached so Settings works offline.
@MainActor
@Observable
final class ModelCatalog {
    /// Fast, inexpensive and good at instruction following — a sensible default for Modes.
    nonisolated static let recommendedTextModel = "gpt-5.4-mini"

    static let knownTranscriptionModels = ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]

    private static let fallbackTextModels = [
        "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4", "gpt-5.5", "gpt-6-luna", "gpt-6-sol",
        "gpt-5.6-luna", "gpt-5-mini", "gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o",
    ]

    private(set) var textModels: [String]
    private(set) var transcriptionModels: [String]
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        textModels = defaults.stringArray(forKey: "catalog.textModels") ?? Self.fallbackTextModels
        transcriptionModels = defaults.stringArray(forKey: "catalog.transcriptionModels") ?? Self.knownTranscriptionModels
    }

    func refresh(apiKey: String?) async {
        guard let apiKey, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let models = try await OpenAIClient(apiKey: apiKey).listModels()
            apply(models)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func apply(_ models: [OpenAIClient.ModelInfo]) {
        let newestFirst = models.sorted { ($0.created ?? 0, $0.id) > ($1.created ?? 0, $1.id) }
        let text = newestFirst.map(\.id).filter(Self.isTextModel)
        let transcription = newestFirst.map(\.id).filter(Self.isFileTranscriptionModel)
        if !text.isEmpty {
            // Recommended first, then newest first.
            textModels = text.filter { $0 == Self.recommendedTextModel } + text.filter { $0 != Self.recommendedTextModel }
            defaults.set(textModels, forKey: "catalog.textModels")
        }
        if !transcription.isEmpty {
            transcriptionModels = Self.knownTranscriptionModels.filter(transcription.contains)
                + transcription.filter { !Self.knownTranscriptionModels.contains($0) }
            defaults.set(transcriptionModels, forKey: "catalog.transcriptionModels")
        }
    }

    /// Models that work with the Responses API for plain text transformation. Excludes audio,
    /// image, embedding and search models, dated snapshots, legacy models, and slow "-pro" tiers.
    nonisolated static func isTextModel(_ id: String) -> Bool {
        let prefixes = ["gpt-", "o1", "o3", "o4", "chat-latest"]
        guard prefixes.contains(where: id.hasPrefix) else { return false }
        let excluded = [
            "audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "moderation",
            "instruct", "live", "diarize", "whisper", "codex", "deep-research", "computer-use",
            "translate", "-pro", "gpt-3.5", "-turbo",
        ]
        if excluded.contains(where: id.contains) { return false }
        if id == "gpt-4" || id.hasPrefix("gpt-4-") { return false }
        if id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// File-upload transcription models (excludes realtime, live and diarization variants).
    nonisolated static func isFileTranscriptionModel(_ id: String) -> Bool {
        if id == "whisper-1" { return true }
        guard id.contains("transcribe") else { return false }
        if ["live", "realtime", "diarize"].contains(where: id.contains) { return false }
        return id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
    }

    static func displayName(forTranscriptionModel model: String) -> String {
        let price = Pricing.transcriptionPerMinute[model].map { String(format: " — $%.4g/min", $0) } ?? ""
        let note = model == "gpt-transcribe" ? " (recommended)" : ""
        return model + note + price
    }
}
