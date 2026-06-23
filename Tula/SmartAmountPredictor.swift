import Foundation

/// Predicts the likely amount for an upcoming recurring expense
/// based on historical spending patterns.
///
/// Three-tier fallback:
/// 1. **Day-of-week** — if 3+ expenses on the same weekday exist,
///    use their weighted average (captures "Sundays cost more" patterns).
/// 2. **Weighted trend** — last 10 expenses, recent ones weighted heavier
///    (captures gradual price changes like subscription increases).
/// 3. **Rule amount** — fallback to the stored `rule.amount`.
enum SmartAmountPredictor {

    struct Prediction {
        let amount: Double
        let confidence: Confidence
        let basis: Basis

        /// Human-readable hint explaining why the predicted amount differs
        /// from the rule's set amount. Returns empty when the prediction
        /// matches the rule amount — no point saying "Based on recent trend"
        /// if the user is logging the same amount they configured.
        func hint(ruleAmount: Double) -> String {
            guard basis != .ruleAmount else { return "" }
            // Same amount (within 1 cent) → no hint needed
            guard abs(amount - ruleAmount) >= 0.01 else { return "" }
            switch basis {
            case .dayOfWeek(let weekday):
                let name = Calendar.current.weekdaySymbols[weekday - 1]  // 1-based → 0-based
                return "Based on your \(name)s"
            case .weightedAverage:
                return "Based on recent trend"
            case .ruleAmount:
                return ""
            }
        }
    }

    enum Confidence {
        /// 5+ data points, low variance
        case high
        /// 3-4 data points or moderate variance
        case medium
        /// 1-2 data points or high variance / pure fallback
        case low
    }

    enum Basis: Equatable {
        /// Day-specific pattern detected; associated value is the weekday (1=Sun … 7=Sat)
        case dayOfWeek(weekday: Int)
        /// Trend from recent expenses (weighted moving average)
        case weightedAverage
        /// Fallback to the rule's stored amount
        case ruleAmount
    }

    // MARK: - Public API

    /// Predicts the expected amount for `rule` on `date`.
    static func predict(for rule: RecurringRule, on date: Date) -> Prediction {
        let history = rule.generatedExpenses
            .sorted { $0.date < $1.date }
            .filter { $0.amount > 0 }

        guard !history.isEmpty else {
            return Prediction(amount: rule.amount, confidence: .low, basis: .ruleAmount)
        }

        let calendar = Calendar.current

        // Tier 1: Day-of-week pattern
        let targetWeekday = calendar.component(.weekday, from: date)
        let sameDayExpenses = history.filter {
            calendar.component(.weekday, from: $0.date) == targetWeekday
        }

        if sameDayExpenses.count >= 3 {
            let avg = weightedAverage(of: sameDayExpenses.map(\.amount))
            let confidence = sameDayExpenses.count >= 5 && coefficientOfVariation(sameDayExpenses.map(\.amount)) < 0.20
                ? Confidence.high : .medium
            return Prediction(
                amount: rounded(avg),
                confidence: confidence,
                basis: .dayOfWeek(weekday: targetWeekday)
            )
        }

        // Tier 2: Weighted trend (last 10 expenses)
        if history.count >= 2 {
            let recent = Array(history.suffix(10))
            let avg = weightedAverage(of: recent.map(\.amount))
            let confidence: Confidence
            if recent.count >= 5 && coefficientOfVariation(recent.map(\.amount)) < 0.20 {
                confidence = .high
            } else if recent.count >= 3 {
                confidence = .medium
            } else {
                confidence = .low
            }
            return Prediction(
                amount: rounded(avg),
                confidence: confidence,
                basis: .weightedAverage
            )
        }

        // Tier 3: Fallback
        return Prediction(amount: rule.amount, confidence: .low, basis: .ruleAmount)
    }

    // MARK: - Math helpers

    /// Weighted average where the most recent value has the highest weight.
    /// Weights: 1, 2, 3, …, N (element at index N-1 = most recent).
    private static func weightedAverage(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var weightedSum = 0.0
        var totalWeight = 0.0
        for (i, value) in values.enumerated() {
            let weight = Double(i + 1)
            weightedSum += value * weight
            totalWeight += weight
        }
        return weightedSum / totalWeight
    }

    /// Coefficient of variation (std-dev / mean). Returns 0 for constant data.
    private static func coefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return sqrt(variance) / mean
    }

    /// Round to 2 decimal places for clean display.
    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
