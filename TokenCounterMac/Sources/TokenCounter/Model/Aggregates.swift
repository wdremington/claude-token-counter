import Foundation

/// Running totals for a slice of records.
struct TokenTotals: Equatable {
    var input = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0
    var thinking = 0
    var responses = 0

    /// Dollars, split by which class of token earned them.
    var costs = CostBreakdown()

    var cost: Double { costs.total }

    /// True while every record folded in had a pricing entry.
    var hasKnownRate: Bool { costs.hasKnownRate }

    /// Every token touched. Thinking tokens are excluded - they are already
    /// counted inside `output`. This weights a cache read like an output token,
    /// which they are not in dollars; it is a volume measure, not an invoice.
    var total: Int { input + cacheWrite + cacheRead + output }

    /// Share of input-side tokens served from cache, which is where the
    /// discount lives.
    var cacheHitRate: Double {
        let inputSide = input + cacheWrite + cacheRead
        return inputSide > 0 ? Double(cacheRead) / Double(inputSide) : 0
    }

    mutating func add(_ r: UsageRecord, cost: CostBreakdown) {
        input += r.inputTokens
        cacheWrite += r.cacheWriteTokens
        cacheRead += r.cacheReadTokens
        output += r.outputTokens
        thinking += r.thinkingTokens
        responses += 1
        costs.add(cost)
    }
}

/// Per-model totals. Properties are flat so tables can sort on key paths.
struct ModelStat: Identifiable, Equatable {
    let id: String
    let displayName: String
    var totals: TokenTotals

    var hasKnownRate: Bool { totals.hasKnownRate }
    var cost: Double { totals.cost }
    var responses: Int { totals.responses }
    var input: Int { totals.input }
    var cacheWrite: Int { totals.cacheWrite }
    var cacheRead: Int { totals.cacheRead }
    var output: Int { totals.output }
    var thinking: Int { totals.thinking }
    var total: Int { totals.total }
}

/// Per-project totals, with a per-model breakdown.
///
/// Identity is the full working directory - two projects can share a last path
/// segment. `label` is the shortest suffix that stays unique across the projects
/// actually in range.
struct ProjectStat: Identifiable, Equatable {
    let id: String
    let label: String
    var totals: TokenTotals
    var models: [ModelStat]

    var path: String { id }
    var cost: Double { totals.cost }
}

/// Per-session totals, so a spend spike can be traced to one conversation.
struct SessionStat: Identifiable, Equatable {
    let id: String
    let projectPath: String
    var projectLabel: String
    var totals: TokenTotals
    var start: Date
    var end: Date

    var cost: Double { totals.cost }

    /// Sessions are named by UUID, which is not worth showing in full.
    var shortID: String { String(id.prefix(8)) }
}

/// One (bucket, series) datum for the chart.
struct SeriesPoint: Identifiable, Equatable {
    var id: String { "\(seriesKey)@\(bucketStart.timeIntervalSince1970)" }
    let bucketStart: Date
    /// The model id, or `Aggregator.otherSeriesKey`.
    let seriesKey: String
    let displayName: String
    let cost: Double
    let tokens: Int

    func value(for metric: ChartMetric) -> Double {
        switch metric {
        case .cost:   return cost
        case .tokens: return Double(tokens)
        }
    }
}

enum ChartMetric: String, CaseIterable, Identifiable, Hashable {
    case cost, tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost:   return "Cost"
        case .tokens: return "Tokens"
        }
    }
}

/// Assigns each model a stable color slot.
///
/// The slot comes from the model's rank across the *entire* dataset, not the
/// filtered range, so narrowing the date range never repaints the series that
/// remain. Ranking is by token volume rather than spend, which keeps colors
/// independent of pricing - otherwise editing a rate override would repaint the
/// legend.
struct ModelColorMap {
    /// Slots 0-6 are named series; everything past that folds into "Other",
    /// which takes slot 7. Categorical hues are never cycled.
    static let namedSeriesLimit = 7

    private var slots: [String: Int] = [:]
    private(set) var namedModels: [String] = []

    init(records: [UsageRecord]) {
        var tokensByModel: [String: Int] = [:]
        var responsesByModel: [String: Int] = [:]
        for r in records {
            tokensByModel[r.model, default: 0] += r.totalTokens
            responsesByModel[r.model, default: 0] += 1
        }

        // Rank by volume, then turns, then id, so the order is deterministic.
        let ranked = tokensByModel.keys.sorted { a, b in
            let ta = tokensByModel[a] ?? 0, tb = tokensByModel[b] ?? 0
            if ta != tb { return ta > tb }
            let ra = responsesByModel[a] ?? 0, rb = responsesByModel[b] ?? 0
            if ra != rb { return ra > rb }
            return a < b
        }

        namedModels = Array(ranked.prefix(Self.namedSeriesLimit))
        for (i, model) in namedModels.enumerated() { slots[model] = i }
    }

    /// The series a model belongs to: itself, or the "Other" bucket.
    func seriesKey(for model: String) -> String {
        slots[model] != nil ? model : Aggregator.otherSeriesKey
    }

    func slot(for seriesKey: String) -> Int {
        slots[seriesKey] ?? Self.namedSeriesLimit
    }
}

/// Everything the dashboard renders for the current range.
struct Aggregates {
    var totals = TokenTotals()
    var models: [ModelStat] = []
    var projects: [ProjectStat] = []
    var sessions: [SessionStat] = []
    var series: [SeriesPoint] = []
    var bucketStarts: [Date] = []
    /// Series keys in color-slot order, for a stable legend and color scale.
    var seriesKeys: [String] = []
    var seriesNames: [String: String] = [:]
    var unpricedModels: [String] = []
    var interval: DateInterval?
    var unit: BucketUnit = .day
    var recordCount = 0

    var isEmpty: Bool { recordCount == 0 }

    /// Total for one bucket, for the chart's hover readout.
    func total(at bucket: Date, metric: ChartMetric) -> Double {
        series.filter { $0.bucketStart == bucket }.reduce(0) { $0 + $1.value(for: metric) }
    }

    func points(at bucket: Date) -> [SeriesPoint] {
        series.filter { $0.bucketStart == bucket }
            .sorted { seriesKeys.firstIndex(of: $0.seriesKey) ?? 0 < seriesKeys.firstIndex(of: $1.seriesKey) ?? 0 }
    }
}

enum Aggregator {
    static let otherSeriesKey = "\u{0000}other"
    static let otherDisplayName = "Other"

    /// Keep the mark count sane when a coarse range is pinned to a fine unit.
    private static let maxBuckets = 1200

    /// Choose the bucket unit, coarsening a pinned choice that would produce
    /// an unreadable number of buckets.
    static func resolveUnit(choice: GranularityChoice, interval: DateInterval?) -> BucketUnit {
        guard let interval else { return .day }
        var unit = choice.unit ?? GranularityChoice.automaticUnit(for: interval)
        while bucketCount(interval: interval, unit: unit) > maxBuckets, let next = unit.coarser {
            unit = next
        }
        return unit
    }

    private static func bucketCount(interval: DateInterval, unit: BucketUnit) -> Int {
        let seconds: Double
        switch unit {
        case .hour:  seconds = 3600
        case .day:   seconds = 86_400
        case .week:  seconds = 604_800
        case .month: seconds = 2_592_000
        }
        return Int(interval.duration / seconds) + 1
    }

    /// Just the dollars for a window, without building the full rollup.
    ///
    /// Budget tracking needs today's and this month's spend on every recompute,
    /// which are almost never the range on screen; two more `build` calls to get
    /// two numbers would be wasteful.
    static func cost(
        records: [UsageRecord],
        interval: DateInterval?,
        includeSidechains: Bool,
        pricer: Pricer
    ) -> Double {
        var total = 0.0
        for r in records {
            if !includeSidechains && r.isSidechain { continue }
            if let interval, r.timestamp < interval.start || r.timestamp > interval.end { continue }
            total += pricer.cost(of: r).total
        }
        return total
    }

    static func build(
        records: [UsageRecord],
        interval: DateInterval?,
        unit: BucketUnit,
        includeSidechains: Bool,
        pricer: Pricer,
        colorMap: ModelColorMap,
        calendar: Calendar
    ) -> Aggregates {
        var out = Aggregates()
        out.interval = interval
        out.unit = unit

        let scoped = records.filter { r in
            if !includeSidechains && r.isSidechain { return false }
            guard let interval else { return true }
            return r.timestamp >= interval.start && r.timestamp <= interval.end
        }
        out.recordCount = scoped.count

        var modelTotals: [String: TokenTotals] = [:]
        var projectTotals: [String: TokenTotals] = [:]
        var projectModelTotals: [String: [String: TokenTotals]] = [:]
        var sessionTotals: [String: TokenTotals] = [:]
        var sessionMeta: [String: (project: String, start: Date, end: Date)] = [:]
        var bucketSeries: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        var unpriced = Set<String>()

        for r in scoped {
            // Priced once per record, then reused for every rollup it feeds.
            let cost = pricer.cost(of: r)
            if !cost.hasKnownRate { unpriced.insert(r.model) }

            out.totals.add(r, cost: cost)
            modelTotals[r.model, default: TokenTotals()].add(r, cost: cost)
            projectTotals[r.projectPath, default: TokenTotals()].add(r, cost: cost)
            projectModelTotals[r.projectPath, default: [:]][r.model, default: TokenTotals()]
                .add(r, cost: cost)

            if !r.sessionID.isEmpty {
                sessionTotals[r.sessionID, default: TokenTotals()].add(r, cost: cost)
                if var meta = sessionMeta[r.sessionID] {
                    meta.start = min(meta.start, r.timestamp)
                    meta.end = max(meta.end, r.timestamp)
                    sessionMeta[r.sessionID] = meta
                } else {
                    sessionMeta[r.sessionID] = (r.projectPath, r.timestamp, r.timestamp)
                }
            }

            let bucket = unit.floor(r.timestamp, calendar: calendar)
            let key = colorMap.seriesKey(for: r.model)
            var entry = bucketSeries[bucket]?[key] ?? (0, 0)
            entry.cost += cost.total
            entry.tokens += r.totalTokens
            bucketSeries[bucket, default: [:]][key] = entry
        }

        // A label depends on which other projects are present, so it can only be
        // decided once every record has been seen.
        let labels = ProjectLabeler.labels(for: Array(projectTotals.keys))

        out.models = modelTotals.map { model, totals in
            ModelStat(id: model, displayName: pricer.displayName(for: model), totals: totals)
        }
        .sorted { $0.cost > $1.cost }

        out.projects = projectTotals.map { path, totals in
            ProjectStat(
                id: path,
                label: labels[path] ?? ProjectLabeler.unknown,
                totals: totals,
                models: (projectModelTotals[path] ?? [:]).map { model, t in
                    ModelStat(id: model, displayName: pricer.displayName(for: model), totals: t)
                }
                .sorted { $0.cost > $1.cost }
            )
        }
        .sorted { $0.cost > $1.cost }

        out.sessions = sessionTotals.compactMap { id, totals in
            guard let meta = sessionMeta[id] else { return nil }
            return SessionStat(
                id: id,
                projectPath: meta.project,
                projectLabel: labels[meta.project] ?? ProjectLabeler.unknown,
                totals: totals,
                start: meta.start,
                end: meta.end
            )
        }
        .sorted { $0.cost > $1.cost }

        out.unpricedModels = unpriced.sorted()

        // Series keys in slot order, so colors and the legend stay stable.
        let present = Set(bucketSeries.values.flatMap(\.keys))
        out.seriesKeys = present.sorted { colorMap.slot(for: $0) < colorMap.slot(for: $1) }
        out.seriesNames = Dictionary(uniqueKeysWithValues: out.seriesKeys.map { key in
            (key, key == otherSeriesKey ? otherDisplayName : pricer.displayName(for: key))
        })

        // Every bucket in range, including empty ones, so gaps read as gaps.
        out.bucketStarts = bucketStarts(interval: interval, unit: unit, calendar: calendar,
                                        fallback: bucketSeries.keys.sorted())

        out.series = out.bucketStarts.flatMap { bucket -> [SeriesPoint] in
            out.seriesKeys.map { key in
                let v = bucketSeries[bucket]?[key] ?? (cost: 0, tokens: 0)
                return SeriesPoint(
                    bucketStart: bucket,
                    seriesKey: key,
                    displayName: out.seriesNames[key] ?? key,
                    cost: v.cost,
                    tokens: v.tokens
                )
            }
        }

        return out
    }

    private static func bucketStarts(
        interval: DateInterval?,
        unit: BucketUnit,
        calendar: Calendar,
        fallback: [Date]
    ) -> [Date] {
        guard let interval else { return fallback }
        var out: [Date] = []
        var cursor = unit.floor(interval.start, calendar: calendar)
        let last = unit.floor(interval.end, calendar: calendar)
        while cursor <= last && out.count <= maxBuckets {
            out.append(cursor)
            let next = unit.advance(cursor, calendar: calendar)
            if next <= cursor { break }
            cursor = next
        }
        return out
    }
}
