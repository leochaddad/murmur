import XCTest
@testable import Murmur

@MainActor
final class StoreTests: XCTestCase {
    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("murmur-tests-\(UUID().uuidString)-\(name)")
    }

    func testModeStoreSeedsDefaultAndExamples() {
        let store = ModeStore(fileURL: temporaryFile("modes.json"), exampleModel: "gpt-5.4-mini")
        XCTAssertEqual(store.modes.first?.id, Mode.defaultID)
        XCTAssertEqual(store.customModes.map(\.name), ["English", "Structure"])
    }

    func testDefaultModeCannotBeDeletedOrRenamed() {
        let store = ModeStore(fileURL: temporaryFile("modes.json"))
        store.delete(Mode.defaultID)
        XCTAssertEqual(store.modes.first?.id, Mode.defaultID)

        var renamed = store.modes[0]
        renamed.name = "Something else"
        renamed.prompt = "Do things"
        store.update(renamed)
        XCTAssertEqual(store.modes[0].name, "Default")
        XCTAssertEqual(store.modes[0].prompt, "")
    }

    func testReorderKeepsDefaultFirstAndPersists() throws {
        let url = temporaryFile("modes.json")
        let store = ModeStore(fileURL: url)
        let added = store.add(model: "gpt-5.4-nano")
        store.moveCustomModes(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.modes.first?.id, Mode.defaultID)
        XCTAssertEqual(store.customModes.first?.id, added.id)
        store.save()

        let reloaded = ModeStore(fileURL: url)
        XCTAssertEqual(reloaded.modes.map(\.id), store.modes.map(\.id))
    }

    func testResolveFallsBackToDefaultForDisabledOrMissingModes() {
        let store = ModeStore(fileURL: temporaryFile("modes.json"))
        var english = store.customModes[0]
        XCTAssertEqual(store.resolve(english.id).id, english.id)
        english.isEnabled = false
        store.update(english)
        XCTAssertEqual(store.resolve(english.id).id, Mode.defaultID)
        XCTAssertEqual(store.resolve(UUID()).id, Mode.defaultID)
        XCTAssertEqual(store.resolve(nil).id, Mode.defaultID)
    }

    func testUsageAggregatesByDayAndMonth() {
        let usage = UsageStore(fileURL: temporaryFile("usage.json"))
        let calendar = Calendar.current
        let now = Date()
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!

        usage.recordTranscription(model: "gpt-transcribe", audioSeconds: 59.2, billedSeconds: 60, date: now)
        usage.recordTranscription(model: "gpt-transcribe", audioSeconds: 120, date: lastMonth)
        usage.recordModeProcessing(ModeOutput(text: "x", model: "gpt-5.4-mini", inputTokens: 1000, cachedInputTokens: 0, outputTokens: 100), date: now)
        usage.recordModeProcessing(ModeOutput(text: "x", model: "unknown-model", inputTokens: 10, cachedInputTokens: 0, outputTokens: 10), date: now)

        XCTAssertEqual(usage.today.dictations, 1)
        XCTAssertEqual(usage.today.audioSeconds, 59.2, accuracy: 1e-9)
        XCTAssertEqual(usage.thisMonth.audioSeconds, 59.2, accuracy: 1e-9)
        XCTAssertEqual(usage.allTime.audioSeconds, 179.2, accuracy: 1e-9)
        XCTAssertEqual(usage.allTime.transcriptionCost, 0.0135, accuracy: 1e-9)
        XCTAssertEqual(usage.today.modeRequests, 2)
        XCTAssertEqual(usage.today.unpricedRequests, 1)
        XCTAssertEqual(usage.today.modeCost, (1000 * 0.75 + 100 * 4.5) / 1_000_000, accuracy: 1e-12)
    }

    func testModelCatalogFilters() {
        let text = ["gpt-5.4-mini", "gpt-6-luna", "gpt-4.1", "chat-latest", "o4-mini"]
        let notText = ["gpt-4o-transcribe", "gpt-realtime", "gpt-image-2", "text-embedding-3-small", "gpt-5.4-mini-2026-03-17",
                       "gpt-5-pro", "gpt-5.1-codex", "gpt-4o-mini-tts", "gpt-3.5-turbo", "gpt-4", "gpt-4-turbo", "o3-deep-research",
                       "gpt-audio", "whisper-1", "sora-2", "omni-moderation-latest", "gpt-4o-search-preview"]
        for id in text { XCTAssertTrue(ModelCatalog.isTextModel(id), id) }
        for id in notText { XCTAssertFalse(ModelCatalog.isTextModel(id), id) }

        XCTAssertTrue(ModelCatalog.isFileTranscriptionModel("gpt-transcribe"))
        XCTAssertTrue(ModelCatalog.isFileTranscriptionModel("whisper-1"))
        XCTAssertFalse(ModelCatalog.isFileTranscriptionModel("gpt-live-transcribe"))
        XCTAssertFalse(ModelCatalog.isFileTranscriptionModel("gpt-4o-transcribe-diarize"))
        XCTAssertFalse(ModelCatalog.isFileTranscriptionModel("gpt-4o-mini-transcribe-2025-12-15"))
    }

    func testOpenAIErrorMapping() {
        func body(_ code: String?, _ message: String = "m", param: String? = nil) -> Data {
            try! JSONSerialization.data(withJSONObject: ["error": ["message": message, "code": code as Any, "param": param as Any]])
        }
        XCTAssertEqual(OpenAIError.from(status: 401, body: body("invalid_api_key")), .invalidAPIKey)
        XCTAssertEqual(OpenAIError.from(status: 429, body: body("insufficient_quota")), .insufficientQuota)
        XCTAssertEqual(OpenAIError.from(status: 429, body: body("rate_limit_exceeded")), .rateLimited)
        XCTAssertEqual(OpenAIError.from(status: 400, body: body("unsupported_value", "bad", param: "reasoning.effort")), .badRequest(message: "bad", param: "reasoning.effort"))
        XCTAssertTrue(OpenAIError.from(status: 503, body: Data()).isTransient)
        XCTAssertFalse(OpenAIError.invalidAPIKey.isTransient)
    }
}
