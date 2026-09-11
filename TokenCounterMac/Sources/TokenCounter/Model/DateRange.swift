import Foundation

/// A named span of time the dashboard can be scoped to.
enum RangePreset: String, CaseIterable, Identifiable, Hashable {
    case last1Hour
    case today
    case yesterday
    case last24Hours
    case last7Days
    case last30Days
    case thisWeek
    case thisMonth
    case lastMonth
    case last90Days
    case thisYear
    case allTime
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last1Hour:   return "Last hour"
        case .today:       return "Today"
        case .yesterday:   return "Yesterday"
        case .last24Hours: return "Last 24 hours"
        case .last7Days:   return "Last 7 days"
        case .last30Days:  return "Last 30 days"
        case .thisWeek:    return "This week"
        case .thisMonth:   return "This month"
        case .lastMonth:   return "Last month"
        case .last90Days:  return "Last 90 days"
        case .thisYear:    return "This year"
        case .allTime:     return "All time"
        case .custom:      return "Custom range"
        }
    }

    /// Presets grouped for the picker menu.
    static let rollingGroup: [RangePreset] = [.last1Hour, .last24Hours, .last7Days, .last30Days, .last90Days]
    static let calendarGroup: [RangePreset] = [.today, .yesterday, .thisWeek, .thisMonth, .lastMonth, .thisYear]

    /// Resolve to a concrete interval.
    ///
    /// - Parameters:
    ///   - custom: the user's start/end, used only by `.custom`.
    ///   - dataBounds: the span actually covered by the logs, used by `.allTime`.
    /// - Returns: nil when the preset has nothing to resolve against (no data).
    func interval(
        now: Date,
        calendar: Calendar,
        custom: DateInterval?,
        dataBounds: DateInterval?
    ) -> DateInterval? {
        switch self {
        case .custom:
            guard let custom else { return nil }
            // Tolerate the user dragging end before start.
            return custom.end >= custom.start
                ? custom
                : DateInterval(start: custom.end, end: custom.start)

        case .allTime:
            return dataBounds

        case .last1Hour:   return rolling(hours: 1, from: now)
        case .last24Hours: return rolling(hours: 24, from: now)
        case .last7Days:   return rolling(days: 7, from: now, calendar: calendar)
        case .last30Days:  return rolling(days: 30, from: now, calendar: calendar)
        case .last90Days:  return rolling(days: 90, from: now, calendar: calendar)

        case .today:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: endOfDay(start, calendar: calendar))

        case .yesterday:
            guard let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
            else { return nil }
            return DateInterval(start: start, end: endOfDay(start, calendar: calendar))

        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)

        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)

        case .lastMonth:
            guard let anchor = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: anchor)

        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)
        }
    }

    private func rolling(hours: Int, from now: Date) -> DateInterval? {
        guard let start = Calendar.current.date(byAdding: .hour, value: -hours, to: now) else { return nil }
        return DateInterval(start: start, end: now)
    }

    /// A rolling window of whole days, ending at the close of today, so the
    /// chart's last bucket is the current day rather than a partial one.
    private func rolling(days: Int, from now: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return nil }
        return DateInterval(start: start, end: endOfDay(today, calendar: calendar))
    }

    private func endOfDay(_ dayStart: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: DateComponents(day: 1, second: -1), to: dayStart) ?? dayStart
    }
}

/// How the time axis is bucketed.
enum BucketUnit: String, CaseIterable, Identifiable, Hashable {
    case hour, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour:  return "Hourly"
        case .day:   return "Daily"
        case .week:  return "Weekly"
        case .month: return "Monthly"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .hour:  return .hour
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        }
    }

    /// The start of the bucket containing `date`.
    func floor(_ date: Date, calendar: Calendar) -> Date {
        switch self {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start
                ?? calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date))
                ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    func advance(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: component, value: 1, to: date) ?? date.addingTimeInterval(3600)
    }

    /// The next coarser unit, used to keep the bucket count sane.
    var coarser: BucketUnit? {
        switch self {
        case .hour:  return .day
        case .day:   return .week
        case .week:  return .month
        case .month: return nil
        }
    }
}

/// The granularity control: follow the range, or pin a unit.
enum GranularityChoice: String, CaseIterable, Identifiable, Hashable {
    case automatic, hour, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .hour:      return "Hourly"
        case .day:       return "Daily"
        case .week:      return "Weekly"
        case .month:     return "Monthly"
        }
    }

    var unit: BucketUnit? {
        switch self {
        case .automatic: return nil
        case .hour:      return .hour
        case .day:       return .day
        case .week:      return .week
        case .month:     return .month
        }
    }

    /// A unit that keeps the bucket count readable for the given span.
    static func automaticUnit(for interval: DateInterval) -> BucketUnit {
        let hours = interval.duration / 3600
        if hours <= 48 { return .hour }
        if hours <= 24 * 70 { return .day }
        if hours <= 24 * 400 { return .week }
        return .month
    }
}
