import Foundation
import ScopeAdapters

/// How token counts read, in `scope list`, `scope summary` and the app's meter: `1.2M`, `850k`, `1.2M · 5h`.
public enum TokenUsageText {
    /// `0`, `999`, `1.5k`, `12k`, `1.2M`, `12M`, `1.2B`: two significant figures below ten of a unit, whole units above.
    public static func compact(_ count: Int) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "k")]
        let value = Double(count)
        for (size, suffix) in units where value >= size * 0.9995 {
            let scaled = value / size
            if scaled < 9.95 {
                let text = String(format: "%.1f", scaled)
                return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
            }
            return "\(Int(scaled.rounded()))" + suffix
        }
        return "\(count)"
    }

    /// The `tokens` field of a thread in `scope list`: what it consumed over the last five hours. `nil` for a thread
    /// Scope reads no transcript for (not Claude Code, or no prompt yet).
    public static func threadField(_ row: TokenUsageSnapshot.Row?) -> String? {
        guard let row else { return nil }
        return compact(row.windows.fiveHours.counts.total) + " · 5h"
    }

    /// `scope summary`'s note on what the token figures are.
    public static let summaryLimit = "Tokens are read from Claude Code transcripts (subagents included, cache reads included) for threads Scope ran; other drivers report none, and a thread closed more than 90 days ago is forgotten."
}

/// What the tokens would have cost on the Anthropic API, for someone on a subscription who wants a sense of scale. Never
/// the bill: a subscription is not charged per token.
public enum TokenPricing {
    /// Dollars per million tokens. Cache writes are priced from `input`: 1.25× for five minutes, 2× for an hour.
    public struct Price: Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double

        public init(input: Double, output: Double, cacheRead: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
        }
    }

    /// Model id prefixes, longest first. First-party list prices as of 2026-10.
    public static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-4-6", Price(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-sonnet-4-5", Price(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-5-5", Price(input: 0.1, output: 0.5, cacheRead: 0.01)),
        ("claude-haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.1)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    public static func price(for model: String) -> Price? {
        // A suffix such as `[1m]` or a date does not change the family.
        table.first { model.hasPrefix($0.prefix) }?.price
    }

    public static func dollars(_ counts: TokenCounts, at price: Price) -> Double {
        let fiveMinuteWrites = Double(counts.cacheCreation - counts.cacheCreation1h)
        let perToken = Double(counts.input) * price.input + Double(counts.output) * price.output
            + fiveMinuteWrites * price.input * 1.25 + Double(counts.cacheCreation1h) * price.input * 2
            + Double(counts.cacheRead) * price.cacheRead
        return perToken / 1_000_000
    }

    /// The API-equivalent cost of `byModel`, and the models no price is known for (left out of the sum).
    public static func dollars(byModel: [String: TokenCounts]) -> (dollars: Double, unpriced: [String]) {
        var total = 0.0
        var unpriced: [String] = []
        for (model, counts) in byModel {
            if let price = price(for: model) { total += dollars(counts, at: price) } else { unpriced.append(model) }
        }
        return (total, unpriced.sorted())
    }
}
