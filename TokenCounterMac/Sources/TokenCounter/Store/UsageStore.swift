import Foundation
import Observation

/// Owns the parsed usage data, the current range selection, and the file watch.
@MainActor
@Observable
final class UsageStore {

    // MARK: - Data

    private(set) var records: [UsageRecord] = []
    private(set) var dataBounds: DateInterval?
    private(set) var colorMap = ModelColorMap(records: [])

    private(set) var isScanning = false
    private(set) var hasLoadedOnce = false
    private(set) var lastScan: Date?
    private(set) var scanError: String?
    private(set) var rootExists = true
    private(set) var fileCount = 0
    private(set) var duplicatesCollapsed = 0
    /// Records the logs no longer contain, recovered from the archive.
    private(set) var archivedRecordCount = 0

    /// Everything the dashboard renders, recomputed when data, selection, or
    /// rates change.
    private(set) var aggregates = Aggregates()
    /// Totals for the menu bar's own (usually narrower) range.
    private(set) var menuBarTotals = TokenTotals()
    private(set) var menuBarModels: [ModelStat] = []

    let pricing: PricingStore
    let archive: UsageArchive
    let budgets: BudgetStore

    /// Where logs are read from. Configurable because `CLAUDE_CONFIG_DIR` moves
    /// it, and a Finder-launched app never sees that shell variable.
    private(set) var root: URL

    // MARK: - Selection

    var preset: RangePreset = .last7Days {
        didSet { guard preset != oldValue else { return }; selectionChanged() }
    }
    var customStart: Date {
        didSet { guard customStart != oldValue else { return }; selectionChanged() }
    }
    var customEnd: Date {
        didSet { guard customEnd != oldValue else { return }; selectionChanged() }
    }
    var granularity: GranularityChoice = .automatic {
        didSet { guard granularity != oldValue else { return }; selectionChanged() }
    }
    var metric: ChartMetric = .cost {
        didSet { guard metric != oldValue else { return }; persist() }
    }
    var includeSidechains = true {
        didSet { guard includeSidechains != oldValue else { return }; selectionChanged() }
    }
    /// `nil` means "follow the dashboard", which is the default - otherwise the
    /// menu bar and the window can silently disagree about what they are showing.
    var menuBarPreset: RangePreset? = nil {
        didSet { guard menuBarPreset != oldValue else { return }; selectionChanged() }
    }

    // MARK: - Internals

    private var states: [URL: LogScanner.FileState] = [:]
    private var watcher: DirectoryWatcher?
    private var debounceTask: Task<Void, Never>?
    private var calendar = Calendar.current

    init(
        root: URL? = nil,
        pricing: PricingStore? = nil,
        archive: UsageArchive? = nil,
        budgets: BudgetStore? = nil
    ) {
        let pricing = pricing ?? PricingStore()
        self.pricing = pricing
        self.archive = archive ?? UsageArchive()
        self.budgets = budgets ?? BudgetStore()
        self.root = root ?? Self.resolvedRoot(override: UserDefaults.standard.string(forKey: Key.logRoot))
        let now = Date()
        self.customStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        self.customEnd = now
        loadPreferences()

        // A rate change must never invalidate the scanner's incremental cache.
        pricing.onChange = { [weak self] in self?.recompute() }

        Task { await self.start() }
    }

    /// Explicit setting first, then the environment, then the standard location.
    nonisolated static func resolvedRoot(override: String?) -> URL {
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return LogScanner.defaultRoot
    }

    var logRootOverride: String? {
        get { UserDefaults.standard.string(forKey: Key.logRoot) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespaces)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: Key.logRoot)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.logRoot)
            }
            let resolved = Self.resolvedRoot(override: trimmed)
            guard resolved != root else { return }
            root = resolved
            watcher?.stop()
            watcher = nil
            states = [:]
            Task {
                await rescan(fullReload: true)
                startWatching()
            }
        }
    }

    // MARK: - Range resolution

    /// The custom range as the user has it set.
    var customInterval: DateInterval {
        customEnd >= customStart
            ? DateInterval(start: customStart, end: customEnd)
            : DateInterval(start: customEnd, end: customStart)
    }

    var resolvedInterval: DateInterval? {
        preset.interval(now: Date(), calendar: calendar, custom: customInterval, dataBounds: dataBounds)
    }

    /// The unit actually charted, after automatic selection and any coarsening.
    var resolvedUnit: BucketUnit {
        Aggregator.resolveUnit(choice: granularity, interval: resolvedInterval)
    }

    /// True when a pinned granularity had to be coarsened to stay readable.
    var granularityWasCoarsened: Bool {
        guard let pinned = granularity.unit else { return false }
        return pinned != resolvedUnit
    }

    /// What the menu bar is actually summarising.
    var menuBarLabel: String { (menuBarPreset ?? preset).title }

    // MARK: - Lifecycle

    func start() async {
        await rescan(fullReload: false)
        startWatching()
        await pricing.refresh()
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(url: root) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRescan() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Collapse a burst of file events into one rescan.
    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.rescan(fullReload: false)
        }
    }

    func refresh() {
        Task { await rescan(fullReload: false) }
    }

    func reloadFromScratch() {
        Task { await rescan(fullReload: true) }
    }

    private func rescan(fullReload: Bool) async {
        guard !isScanning else { return }
        isScanning = true

        let previous = fullReload ? [:] : states
        let result = await LogScanner.scan(root: root, previous: previous)

        states = result.states
        fileCount = result.fileCount
        // Counted from the live scan, before the archive merge: the archive
        // contributes records but no raw log lines, so folding it in first would
        // drive this negative.
        duplicatesCollapsed = result.duplicatesCollapsed
        rootExists = result.rootExists
        scanError = result.error

        records = archive.integrate(live: result.records)
        archive.flush()
        archivedRecordCount = max(0, records.count - result.records.count)

        // From the merged set, not the scan: the archive usually reaches back
        // further than the logs still on disk.
        if let first = records.first?.timestamp, let last = records.last?.timestamp {
            dataBounds = DateInterval(start: first, end: max(last, first))
        } else {
            dataBounds = nil
        }
        colorMap = ModelColorMap(records: records)
        lastScan = Date()
        hasLoadedOnce = true
        isScanning = false

        recompute()
    }

    // MARK: - Derived state

    private func selectionChanged() {
        persist()
        recompute()
    }

    private func recompute() {
        calendar = Calendar.current
        let pricer = pricing.pricer

        aggregates = Aggregator.build(
            records: records,
            interval: resolvedInterval,
            unit: resolvedUnit,
            includeSidechains: includeSidechains,
            pricer: pricer,
            colorMap: colorMap,
            calendar: calendar
        )

        let menuInterval = (menuBarPreset ?? preset).interval(
            now: Date(), calendar: calendar, custom: customInterval, dataBounds: dataBounds
        )
        let menuAgg = Aggregator.build(
            records: records,
            interval: menuInterval,
            unit: .day,
            includeSidechains: includeSidechains,
            pricer: pricer,
            colorMap: colorMap,
            calendar: calendar
        )
        menuBarTotals = menuAgg.totals
        menuBarModels = menuAgg.models

        // Budgets track fixed calendar windows, not whatever range is on screen.
        let now = Date()
        func spend(_ preset: RangePreset) -> Double {
            Aggregator.cost(
                records: records,
                interval: preset.interval(now: now, calendar: calendar, custom: nil, dataBounds: nil),
                includeSidechains: includeSidechains,
                pricer: pricer
            )
        }
        budgets.update(dailySpend: spend(.today), monthlySpend: spend(.thisMonth), now: now)
    }

    /// Re-resolve rolling ranges so "Today" and "Last hour" stay honest as
    /// wall-clock time advances.
    func refreshTimeDependentRanges() {
        let rolling: Set<RangePreset> = [
            .last1Hour, .last24Hours, .today, .last7Days, .last30Days,
            .last90Days, .thisWeek, .thisMonth, .thisYear,
        ]
        if rolling.contains(preset) || rolling.contains(menuBarPreset ?? preset) {
            recompute()
        }
    }

    /// Point the custom range at the full extent of the data, so switching to
    /// "Custom range" starts from something sensible rather than a stale span.
    func seedCustomRangeFromCurrentSelection() {
        guard let current = resolvedInterval else { return }
        customStart = current.start
        customEnd = current.end
    }

    // MARK: - Preferences

    private enum Key {
        static let preset = "range.preset"
        static let customStart = "range.customStart"
        static let customEnd = "range.customEnd"
        static let granularity = "chart.granularity"
        static let metric = "chart.metric"
        static let sidechains = "filter.includeSidechains"
        static let menuBarPreset = "menuBar.preset"
        static let logRoot = "logs.rootOverride"
    }

    private var isLoadingPreferences = false

    private func loadPreferences() {
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }

        let d = UserDefaults.standard
        if let raw = d.string(forKey: Key.preset), let v = RangePreset(rawValue: raw) { preset = v }
        if let raw = d.string(forKey: Key.granularity), let v = GranularityChoice(rawValue: raw) { granularity = v }
        if let raw = d.string(forKey: Key.metric), let v = ChartMetric(rawValue: raw) { metric = v }
        if let raw = d.string(forKey: Key.menuBarPreset) { menuBarPreset = RangePreset(rawValue: raw) }
        if d.object(forKey: Key.sidechains) != nil { includeSidechains = d.bool(forKey: Key.sidechains) }

        let start = d.double(forKey: Key.customStart)
        let end = d.double(forKey: Key.customEnd)
        if start > 0, end > 0 {
            customStart = Date(timeIntervalSince1970: start)
            customEnd = Date(timeIntervalSince1970: end)
        }
    }

    private func persist() {
        guard !isLoadingPreferences else { return }
        let d = UserDefaults.standard
        d.set(preset.rawValue, forKey: Key.preset)
        d.set(granularity.rawValue, forKey: Key.granularity)
        d.set(metric.rawValue, forKey: Key.metric)
        d.set(includeSidechains, forKey: Key.sidechains)
        d.set(customStart.timeIntervalSince1970, forKey: Key.customStart)
        d.set(customEnd.timeIntervalSince1970, forKey: Key.customEnd)
        if let menuBarPreset {
            d.set(menuBarPreset.rawValue, forKey: Key.menuBarPreset)
        } else {
            d.removeObject(forKey: Key.menuBarPreset)
        }
    }

    // MARK: - Export

    /// The current range's per-model rows as CSV.
    func exportCSV() -> String {
        var lines = [
            "# TokenCounter export — Anthropic API list prices; not a bill,",
            "# and not reflective of Max/Pro subscriptions or Bedrock/Vertex rates.",
            "model,responses,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,"
                + "thinking_tokens,total_tokens,cost_input_usd,cost_cache_write_usd,"
                + "cost_cache_read_usd,cost_output_usd,cost_long_context_usd,cost_usd",
        ]
        func row(_ name: String, _ t: TokenTotals) -> String {
            [
                name, "\(t.responses)", "\(t.input)", "\(t.cacheWrite)", "\(t.cacheRead)",
                "\(t.output)", "\(t.thinking)", "\(t.total)",
                money(t.costs.input), money(t.costs.cacheWrite), money(t.costs.cacheRead),
                money(t.costs.output), money(t.costs.longContextSurcharge), money(t.cost),
            ].joined(separator: ",")
        }
        for m in aggregates.models { lines.append(row(csvSafe(m.id), m.totals)) }
        lines.append(row("TOTAL", aggregates.totals))
        return lines.joined(separator: "\n")
    }

    private func money(_ v: Double) -> String { String(format: "%.6f", v) }

    /// Model ids are log-derived, so quote anything that would break a column.
    private func csvSafe(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
