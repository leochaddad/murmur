import SwiftUI

struct UsageSettingsView: View {
    @Environment(UsageStore.self) private var usage
    @State private var confirmingReset = false

    var body: some View {
        let columns = [usage.today, usage.thisMonth, usage.allTime]
        Form {
            Section {
                Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 7) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Today")
                        Text("This Month")
                        Text("All Time")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider()
                    row("Dictations", columns) { "\($0.dictations)" }
                    row("Minutes transcribed", columns) { String(format: "%.1f", $0.minutes) }
                    row("Transcription", columns) { Self.money($0.transcriptionCost) }
                    Divider()
                    row("Mode requests", columns) { "\($0.modeRequests)" }
                    row("Tokens in / out", columns) { "\(Self.compact($0.inputTokens)) / \(Self.compact($0.outputTokens))" }
                    row("Mode processing", columns) { Self.money($0.modeCost) }
                    Divider()
                    row("Estimated total", columns) { Self.money($0.totalCost) }
                        .fontWeight(.semibold)
                }
                .monospacedDigit()
                .padding(.vertical, 4)
            } header: {
                Text("OpenAI Usage")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFootnote("Local estimates calculated on this Mac with OpenAI’s list prices as of \(Pricing.asOf). Your OpenAI billing dashboard is the authoritative record.")
                    if usage.allTime.unpricedRequests > 0 {
                        SettingsFootnote("\(usage.allTime.unpricedRequests) request(s) used models without a known price and aren’t included in the cost.")
                    }
                    Link("Open OpenAI usage dashboard", destination: URL(string: "https://platform.openai.com/usage")!)
                }
            }

            Section {
                HStack {
                    if let first = usage.firstDay {
                        Text("Tracking since \(first.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Statistics…", role: .destructive) { confirmingReset = true }
                        .disabled(usage.days.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Reset usage statistics?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { usage.reset() }
        } message: {
            Text("This clears Murmur’s local statistics. It doesn’t affect your OpenAI account.")
        }
    }

    private func row(_ title: String, _ columns: [UsageTotals], value: (UsageTotals) -> String) -> some View {
        let values = columns.map(value)
        return GridRow {
            Text(title).gridColumnAlignment(.leading)
            ForEach(values.indices, id: \.self) { index in
                Text(values[index])
            }
        }
    }

    static func money(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    static func compact(_ value: Int) -> String {
        value >= 10_000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
    }
}
