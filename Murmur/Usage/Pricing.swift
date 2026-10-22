import Foundation

/// Public OpenAI list prices used for local cost *estimates*. OpenAI's billing dashboard is
/// the source of truth; these numbers only make the Usage view meaningful offline.
enum Pricing {
    static let asOf = "October 2026"

    struct TokenPrice: Equatable {
        /// USD per 1M tokens.
        let input: Double
        let cachedInput: Double
        let output: Double
    }

    /// USD per minute of audio.
    static let transcriptionPerMinute: [String: Double] = [
        "gpt-transcribe": 0.0045,
        "gpt-4o-transcribe": 0.006,
        "gpt-4o-mini-transcribe": 0.003,
        "whisper-1": 0.006,
    ]

    static let textModels: [String: TokenPrice] = [
        "gpt-6-astra": .init(input: 10.00, cachedInput: 1.00, output: 50.00),
        "gpt-6-sol": .init(input: 2.00, cachedInput: 0.20, output: 10.00),
        "gpt-6.1-sol": .init(input: 2.00, cachedInput: 0.10, output: 10.00),
        "gpt-6-luna": .init(input: 0.10, cachedInput: 0.01, output: 0.50),
        "gpt-5.6-sol": .init(input: 4.00, cachedInput: 0.40, output: 20.00),
        "gpt-5.6-terra": .init(input: 2.00, cachedInput: 0.20, output: 12.00),
        "gpt-5.6-luna": .init(input: 0.20, cachedInput: 0.02, output: 1.20),
        "gpt-5.5": .init(input: 5.00, cachedInput: 0.50, output: 30.00),
        "gpt-5.4": .init(input: 2.50, cachedInput: 0.25, output: 15.00),
        "gpt-5.4-mini": .init(input: 0.75, cachedInput: 0.075, output: 4.50),
        "gpt-5.4-nano": .init(input: 0.20, cachedInput: 0.02, output: 1.25),
        "gpt-5.2": .init(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.1": .init(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5": .init(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5-mini": .init(input: 0.25, cachedInput: 0.025, output: 2.00),
        "gpt-5-nano": .init(input: 0.05, cachedInput: 0.005, output: 0.40),
        "gpt-4.1": .init(input: 2.00, cachedInput: 0.50, output: 8.00),
        "gpt-4.1-mini": .init(input: 0.40, cachedInput: 0.10, output: 1.60),
        "gpt-4.1-nano": .init(input: 0.10, cachedInput: 0.025, output: 0.40),
        "gpt-4o": .init(input: 2.50, cachedInput: 1.25, output: 10.00),
        "gpt-4o-mini": .init(input: 0.15, cachedInput: 0.075, output: 0.60),
        "o3": .init(input: 2.00, cachedInput: 0.50, output: 8.00),
        "o4-mini": .init(input: 1.10, cachedInput: 0.275, output: 4.40),
        "chat-latest": .init(input: 5.00, cachedInput: 0.50, output: 30.00),
    ]

    /// Maps dated snapshots ("gpt-5.4-mini-2026-03-17") to their base model.
    static func baseModel(_ model: String) -> String {
        model.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
    }

    static func transcriptionCost(model: String, seconds: Double) -> Double? {
        transcriptionPerMinute[baseModel(model)].map { $0 * seconds / 60 }
    }

    static func textPrice(for model: String) -> TokenPrice? {
        textModels[baseModel(model)]
    }

    static func textCost(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double? {
        guard let price = textPrice(for: model) else { return nil }
        let uncached = max(0, inputTokens - cachedInputTokens)
        return (Double(uncached) * price.input + Double(cachedInputTokens) * price.cachedInput + Double(outputTokens) * price.output) / 1_000_000
    }

    static func describe(_ price: TokenPrice) -> String {
        "\(usd(price.input)) in · \(usd(price.output)) out per 1M tokens"
    }

    /// "$0.75", "$4.50", "$0.075".
    static func usd(_ value: Double) -> String {
        priceFormatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    private static let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter
    }()
}
