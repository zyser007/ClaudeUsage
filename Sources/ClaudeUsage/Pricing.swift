import Foundation

/// Per-MTok rates. Cache multipliers relative to the input rate:
/// write 1.25x (5m TTL), 2x (1h TTL), read 0.1x.
struct Rates {
    let input: Double
    let output: Double

    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2.0 }
    var cacheRead: Double { input * 0.1 }
}

enum Pricing {
    /// Sonnet 5 introductory pricing runs through 2026-08-31.
    private static let sonnet5IntroEnd: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 1
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    static func rates(model: String, at date: Date) -> Rates {
        let m = model.lowercased()

        if m.contains("fable-5") || m.contains("mythos-5") || m.contains("mythos-preview") {
            return Rates(input: 10, output: 50)
        }
        if m.contains("opus") {
            return Rates(input: 5, output: 25)
        }
        if m.contains("sonnet-5") {
            return date < sonnet5IntroEnd
                ? Rates(input: 2, output: 10)
                : Rates(input: 3, output: 15)
        }
        if m.contains("sonnet") {
            return Rates(input: 3, output: 15)
        }
        if m.contains("haiku") {
            return Rates(input: 1, output: 5)
        }
        // Unknown model: bill at Opus tier so cost is never silently understated.
        return Rates(input: 5, output: 25)
    }

    static func cost(of t: Tokens, model: String, at date: Date) -> Double {
        let r = rates(model: model, at: date)
        let perToken = 1_000_000.0
        return (Double(t.input) * r.input
            + Double(t.output) * r.output
            + Double(t.cacheWrite5m) * r.cacheWrite5m
            + Double(t.cacheWrite1h) * r.cacheWrite1h
            + Double(t.cacheRead) * r.cacheRead) / perToken
    }
}
