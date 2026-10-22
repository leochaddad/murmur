import XCTest
@testable import Murmur

final class PricingTests: XCTestCase {
    func testTranscriptionCostIsPerMinute() {
        XCTAssertEqual(Pricing.transcriptionCost(model: "gpt-transcribe", seconds: 60)!, 0.0045, accuracy: 1e-9)
        XCTAssertEqual(Pricing.transcriptionCost(model: "gpt-4o-mini-transcribe", seconds: 30)!, 0.0015, accuracy: 1e-9)
        XCTAssertNil(Pricing.transcriptionCost(model: "some-future-model", seconds: 60))
    }

    func testTextCostSeparatesCachedTokens() {
        // gpt-5.4-mini: $0.75 in, $0.075 cached, $4.50 out per 1M tokens.
        let cost = Pricing.textCost(model: "gpt-5.4-mini", inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000)!
        XCTAssertEqual(cost, 0.6 * 0.75 + 0.4 * 0.075 + 0.1 * 4.5, accuracy: 1e-9)
    }

    func testDatedSnapshotsUseBaseModelPrice() {
        XCTAssertEqual(Pricing.baseModel("gpt-5.4-mini-2026-03-17"), "gpt-5.4-mini")
        XCTAssertEqual(Pricing.textPrice(for: "gpt-4.1-2025-04-14"), Pricing.textPrice(for: "gpt-4.1"))
        XCTAssertEqual(Pricing.baseModel("gpt-5.4-mini"), "gpt-5.4-mini")
    }

    func testPriceFormatting() {
        XCTAssertEqual(Pricing.usd(0.75), "$0.75")
        XCTAssertEqual(Pricing.usd(4.5), "$4.50")
        XCTAssertEqual(Pricing.usd(0.075), "$0.075")
    }
}
