import Foundation
import Observation

struct UsageTotals: Codable, Equatable {
    var dictations = 0
    var audioSeconds: Double = 0
    var transcriptionCost: Double = 0
    var modeRequests = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var modeCost: Double = 0
    /// Requests whose model has no known price (excluded from cost estimates).
    var unpricedRequests = 0

    var totalCost: Double { transcriptionCost + modeCost }
    var minutes: Double { audioSeconds / 60 }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(
            dictations: lhs.dictations + rhs.dictations,
            audioSeconds: lhs.audioSeconds + rhs.audioSeconds,
            transcriptionCost: lhs.transcriptionCost + rhs.transcriptionCost,
            modeRequests: lhs.modeRequests + rhs.modeRequests,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            modeCost: lhs.modeCost + rhs.modeCost,
            unpricedRequests: lhs.unpricedRequests + rhs.unpricedRequests
        )
    }
}

/// Local usage statistics, aggregated per day in ~/Library/Application Support/Murmur/Usage.json.
/// Costs are estimated when each request completes, using the prices in `Pricing`.
@MainActor
@Observable
final class UsageStore {
    private(set) var days: [String: UsageTotals] = [:]

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("Usage.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: UsageTotals].self, from: data) {
            days = saved
        }
    }

    /// `billedSeconds` is what OpenAI charges for (gpt-transcribe rounds up to whole seconds).
    func recordTranscription(model: String, audioSeconds: Double, billedSeconds: Double? = nil, date: Date = Date()) {
        update(date) { totals in
            totals.dictations += 1
            totals.audioSeconds += audioSeconds
            if let cost = Pricing.transcriptionCost(model: model, seconds: billedSeconds ?? audioSeconds) {
                totals.transcriptionCost += cost
            } else {
                totals.unpricedRequests += 1
            }
        }
    }

    func recordModeProcessing(_ output: ModeOutput, date: Date = Date()) {
        update(date) { totals in
            totals.modeRequests += 1
            totals.inputTokens += output.inputTokens
            totals.cachedInputTokens += output.cachedInputTokens
            totals.outputTokens += output.outputTokens
            if let cost = Pricing.textCost(model: output.model, inputTokens: output.inputTokens, cachedInputTokens: output.cachedInputTokens, outputTokens: output.outputTokens) {
                totals.modeCost += cost
            } else {
                totals.unpricedRequests += 1
            }
        }
    }

    var today: UsageTotals { days[dayKey(Date())] ?? UsageTotals() }

    var thisMonth: UsageTotals {
        let prefix = String(dayKey(Date()).prefix(7))
        return days.filter { $0.key.hasPrefix(prefix) }.values.reduce(UsageTotals(), +)
    }

    var allTime: UsageTotals { days.values.reduce(UsageTotals(), +) }

    var firstDay: Date? {
        days.keys.min().flatMap { Self.keyFormatter.date(from: $0) }
    }

    func reset() {
        days = [:]
        save()
    }

    private func update(_ date: Date, _ change: (inout UsageTotals) -> Void) {
        let key = dayKey(date)
        var totals = days[key] ?? UsageTotals()
        change(&totals)
        days[key] = totals
        save()
    }

    private func dayKey(_ date: Date) -> String {
        Self.keyFormatter.string(from: date)
    }

    private func save() {
        do {
            try JSONEncoder().encode(days).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Saving usage failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
