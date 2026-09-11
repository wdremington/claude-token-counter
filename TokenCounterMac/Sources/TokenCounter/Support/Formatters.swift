import Foundation

enum Fmt {
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func integer(_ n: Int) -> String {
        grouping.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Compact token counts: 1.24M, 34.5K, 812.
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return integer(n)
    }

    /// Dollars, with enough precision that small amounts stay legible.
    static func money(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v >= 1_000 { return "$" + (grouping.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))") }
        if v >= 1 { return String(format: "$%.2f", v) }
        if v >= 0.01 { return String(format: "$%.4f", v) }
        return String(format: "$%.6f", v)
    }

    /// Shorter money, for axes and dense rows.
    static func moneyCompact(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v >= 1_000 { return String(format: "$%.1fK", v / 1_000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1 { return String(format: "$%.2f", v) }
        if v >= 0.01 { return String(format: "$%.3f", v) }
        return String(format: "$%.4f", v)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    // MARK: - Dates

    static func axisLabel(_ date: Date, unit: BucketUnit) -> String {
        let f = DateFormatter()
        switch unit {
        case .hour:  f.dateFormat = "ha"
        case .day:   f.dateFormat = "MMM d"
        case .week:  f.dateFormat = "MMM d"
        case .month: f.dateFormat = "MMM yy"
        }
        return f.string(from: date)
    }

    static func bucketTitle(_ date: Date, unit: BucketUnit) -> String {
        let f = DateFormatter()
        switch unit {
        case .hour:  f.dateFormat = "EEE MMM d, h a"
        case .day:   f.dateFormat = "EEE MMM d, yyyy"
        case .week:  f.dateFormat = "'Week of' MMM d, yyyy"
        case .month: f.dateFormat = "MMMM yyyy"
        }
        return f.string(from: date)
    }

    /// A one-line description of the active range, kept short enough to fit a
    /// stat tile: the year is shown only when the range leaves the current one.
    static func rangeLabel(_ interval: DateInterval?) -> String {
        guard let interval else { return "No data" }

        let cal = Calendar.current
        let startYear = cal.component(.year, from: interval.start)
        let endYear = cal.component(.year, from: interval.end)
        let needsYear = startYear != endYear || startYear != cal.component(.year, from: Date())

        let day = DateFormatter()
        day.dateFormat = needsYear ? "MMM d, yyyy" : "MMM d"
        let time = DateFormatter()
        time.dateFormat = "h:mm a"

        if cal.isDate(interval.start, inSameDayAs: interval.end) {
            return "\(day.string(from: interval.start)) · \(time.string(from: interval.start)) – \(time.string(from: interval.end))"
        }
        return "\(day.string(from: interval.start)) – \(day.string(from: interval.end))"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func clockTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }
}
