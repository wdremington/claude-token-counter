import Foundation
import Observation
import UserNotifications

/// Spending limits, and the alerts that fire when they are approached.
///
/// Deliberately quiet: each threshold notifies at most once per period, and the
/// dedupe key is persisted, so relaunching the app does not re-fire an alert the
/// user already saw. Authorization is requested only when alerts are turned on.
@MainActor
@Observable
final class BudgetStore {

    enum Period: String, CaseIterable {
        case daily, monthly

        var title: String { self == .daily ? "Daily" : "Monthly" }
    }

    enum Level: String {
        case warning, exceeded
    }

    /// `nil` means no limit for that period.
    var dailyLimit: Double? {
        didSet { guard dailyLimit != oldValue else { return }; persist() }
    }
    var monthlyLimit: Double? {
        didSet { guard monthlyLimit != oldValue else { return }; persist() }
    }

    /// Fraction of the limit that counts as "getting close".
    var warningThreshold: Double {
        didSet { guard warningThreshold != oldValue else { return }; persist() }
    }

    var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            persist()
            if notificationsEnabled { requestAuthorization() }
        }
    }

    private(set) var authorizationDenied = false

    /// Current spend, refreshed by `UsageStore` on every recompute.
    private(set) var dailySpend = 0.0
    private(set) var monthlySpend = 0.0

    var isActive: Bool { dailyLimit != nil || monthlyLimit != nil }

    /// Injectable so the test suite can use a scratch suite rather than
    /// overwriting the user's real limits and alert history.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        dailyLimit = d.object(forKey: Key.daily) as? Double
        monthlyLimit = d.object(forKey: Key.monthly) as? Double
        warningThreshold = d.object(forKey: Key.threshold) as? Double ?? 0.8
        notificationsEnabled = d.object(forKey: Key.notify) as? Bool ?? false
    }

    // MARK: - Progress

    func limit(for period: Period) -> Double? {
        period == .daily ? dailyLimit : monthlyLimit
    }

    func spend(for period: Period) -> Double {
        period == .daily ? dailySpend : monthlySpend
    }

    /// 0...1+ against the limit, or nil when that period has no limit set.
    func fraction(for period: Period) -> Double? {
        guard let limit = limit(for: period), limit > 0 else { return nil }
        return spend(for: period) / limit
    }

    /// The period closest to its limit, which is the one worth showing.
    var mostPressing: (period: Period, fraction: Double)? {
        Period.allCases
            .compactMap { p in fraction(for: p).map { (p, $0) } }
            .max { $0.1 < $1.1 }
    }

    // MARK: - Evaluation

    func update(dailySpend daily: Double, monthlySpend monthly: Double, now: Date = Date()) {
        dailySpend = daily
        monthlySpend = monthly
        guard notificationsEnabled else { return }
        for period in Period.allCases { evaluate(period, now: now) }
    }

    /// The level that fired, or nil if nothing did - returned so the dedupe
    /// rule can be tested without a notification centre.
    @discardableResult
    func evaluate(_ period: Period, now: Date) -> Level? {
        guard let limit = limit(for: period), limit > 0 else { return nil }
        let spent = spend(for: period)
        let fraction = spent / limit

        // Only the higher level fires: crossing 100% should not also announce 80%.
        let level: Level? = fraction >= 1 ? .exceeded : (fraction >= warningThreshold ? .warning : nil)
        guard let level else { return nil }

        let stamp = Self.periodStamp(period, now: now)
        let key = "\(Key.notifiedPrefix).\(period.rawValue).\(level.rawValue)"
        guard defaults.string(forKey: key) != stamp else { return nil }
        defaults.set(stamp, forKey: key)

        post(period: period, level: level, spent: spent, limit: limit)
        return level
    }

    /// Identifies the current day or month, so a fired alert resets when the
    /// period rolls over but never repeats inside it.
    private static func periodStamp(_ period: Period, now: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: now)
        switch period {
        case .daily:   return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .monthly: return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        }
    }

    // MARK: - Notifications

    /// Notifications need a real bundle identifier. The `--test` and `--audit`
    /// paths run as a bare binary, so every entry point here has to tolerate
    /// there being no notification centre at all.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return .current()
    }

    private func requestAuthorization() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorizationDenied = !granted }
        }
    }

    private func post(period: Period, level: Level, spent: Double, limit: Double) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = level == .exceeded
            ? "\(period.title) budget exceeded"
            : "\(period.title) budget \(Fmt.percent(spent / limit)) used"
        content.body = "\(Fmt.money(spent)) of \(Fmt.money(limit)) — \(Copy.listPriceShort)"

        center.add(UNNotificationRequest(
            identifier: "budget.\(period.rawValue).\(level.rawValue).\(Self.periodStamp(period, now: Date()))",
            content: content,
            trigger: nil
        ))
    }

    /// Lets the user see an alert again in the current period, e.g. after
    /// raising a limit they had already blown through.
    func resetNotificationHistory() {
        let d = defaults
        for period in Period.allCases {
            for level in [Level.warning, .exceeded] {
                d.removeObject(forKey: "\(Key.notifiedPrefix).\(period.rawValue).\(level.rawValue)")
            }
        }
    }

    // MARK: - Persistence

    private enum Key {
        static let daily = "budget.daily"
        static let monthly = "budget.monthly"
        static let threshold = "budget.warningThreshold"
        static let notify = "budget.notificationsEnabled"
        static let notifiedPrefix = "budget.notified"
    }

    private func persist() {
        let d = defaults
        if let dailyLimit { d.set(dailyLimit, forKey: Key.daily) } else { d.removeObject(forKey: Key.daily) }
        if let monthlyLimit { d.set(monthlyLimit, forKey: Key.monthly) } else { d.removeObject(forKey: Key.monthly) }
        d.set(warningThreshold, forKey: Key.threshold)
        d.set(notificationsEnabled, forKey: Key.notify)
    }
}
