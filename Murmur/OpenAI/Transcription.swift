import AVFoundation
import Foundation

struct TranscriptionSettings {
    var model: String
    /// ISO-639-1 code, or nil for automatic detection.
    var language: String?
    var vocabulary: [String]
}

struct Transcript {
    let text: String
    let model: String
    let audioSeconds: Double
    /// Duration OpenAI bills for (whole seconds for duration-billed models), used for cost estimates.
    let billedSeconds: Double
    let detectedLanguage: String?
}

/// Transcription for one dictation.
///
/// The recorder hands every captured buffer to `append` while the user is speaking, and
/// `finish` is called once recording ends. The current implementation is batch-based —
/// it ignores live buffers and uploads the finished file — but a streaming implementation
/// (e.g. OpenAI's realtime transcription over WebSocket) can conform to this protocol and
/// stream `append`ed audio without any change to the rest of the app.
protocol TranscriptionSession: AnyObject {
    /// Called on the audio thread with 16 kHz mono Float32 buffers.
    func append(_ buffer: AVAudioPCMBuffer)
    func finish(audio: RecordedAudio) async throws -> Transcript
}

final class FileTranscriptionSession: TranscriptionSession {
    private let client: OpenAIClient
    private let settings: TranscriptionSettings

    init(client: OpenAIClient, settings: TranscriptionSettings) {
        self.client = client
        self.settings = settings
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(audio: RecordedAudio) async throws -> Transcript {
        // Generous timeout: uploads are small (≈240 KB per minute) but long dictations take
        // the model a while to process.
        let timeout = 30 + audio.duration * 0.5
        let response = try await client.transcribe(
            fileURL: audio.url,
            model: settings.model,
            language: settings.language,
            vocabulary: settings.vocabulary,
            timeout: timeout
        )
        let billed = response.usage?.seconds ?? audio.duration
        return Transcript(
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            model: settings.model,
            audioSeconds: audio.duration,
            billedSeconds: billed,
            detectedLanguage: response.languages?.first?.code
        )
    }
}
