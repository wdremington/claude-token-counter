import Foundation

// MARK: - Context tier

/// Claude Code appends the active context tier to the model id as a bracket
/// suffix (`claude-opus-5[1m]`). For most models the tier does not change the
/// rate, but for Sonnet 4 and Sonnet 4.5 it did - see `LongContextPremium`.
enum ContextTier: String, Codable, Equatable, Sendable {
    case standard
    case oneMillion

    /// Split a logged model id into its canonical id and its tier.
    ///
    /// When there is no suffix the returned id shares storage with `raw`, so the
    /// common case allocates nothing.
    static func split(_ raw: String) -> (id: String, tier: ContextTier) {
        guard let bracket = raw.firstIndex(of: "[") else { return (raw, .standard) }
        let id = String(raw[raw.startIndex..<bracket])
        let suffix = raw[bracket...]
        return (id, suffix.contains("1m") ? .oneMillion : .standard)
    }
}

// MARK: - Rates

/// A surcharge that applies to an entire request once it grows past a threshold.
///
/// Only ever set on Sonnet 4 and Sonnet 4.5, whose 1M-context beta billed the
/// whole request at 2x input / 1.5x output once total input passed 200K. The
/// premium was dropped when 1M context went GA, so every model from Opus 4.6 and
/// Sonnet 4.6 onward leaves this nil.
struct LongContextPremium: Codable, Equatable, Sendable {
    var thresholdInputTokens: Int
    var inputMultiplier: Double
    var outputMultiplier: Double

    static let sonnet1MBeta = LongContextPremium(
        thresholdInputTokens: 200_000,
        inputMultiplier: 2.0,
        outputMultiplier: 1.5
    )
}

/// Anthropic first-party API rates, in dollars per million tokens.
struct ModelRate: Codable, Equatable, Sendable {
    var input: Double
    var output: Double

    /// Some models price cache reads outright instead of as a multiple of `input`.
    var cacheReadPerMTok: Double?

    /// Non-nil only for the two models that ever charged a long-context premium.
    var longContext: LongContextPremium?

    /// A 5-minute-TTL cache write costs 1.25x the base input rate.
    static let cacheWrite5mMultiplier = 1.25
    /// A 1-hour-TTL cache write costs 2x the base input rate.
    static let cacheWrite1hMultiplier = 2.0
    /// A cache read costs 0.1x the base input rate unless the model overrides it.
    static let cacheReadMultiplier = 0.10

    var cacheWrite5mRate: Double { input * Self.cacheWrite5mMultiplier }
    var cacheWrite1hRate: Double { input * Self.cacheWrite1hMultiplier }
    var cacheReadRate: Double { cacheReadPerMTok ?? input * Self.cacheReadMultiplier }

    init(
        input: Double,
        output: Double,
        cacheReadPerMTok: Double? = nil,
        longContext: LongContextPremium? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheReadPerMTok = cacheReadPerMTok
        self.longContext = longContext
    }
}

// MARK: - Cost

/// Cost in dollars, split by which class of token earned it.
///
/// The five token components are always the *base* cost at 1x. Any long-context
/// premium lands in `longContextSurcharge` instead of inflating the components,
/// so the parts sum to the total and the surcharge is visible as its own line.
struct CostBreakdown: Equatable, Sendable {
    var input = 0.0
    var cacheWrite5m = 0.0
    var cacheWrite1h = 0.0
    var cacheRead = 0.0
    var output = 0.0
    var longContextSurcharge = 0.0

    /// False once any record folded in had no pricing entry, so the total is
    /// understated rather than wrong.
    var hasKnownRate = true

    var total: Double {
        input + cacheWrite5m + cacheWrite1h + cacheRead + output + longContextSurcharge
    }

    var cacheWrite: Double { cacheWrite5m + cacheWrite1h }

    mutating func add(_ other: CostBreakdown) {
        input += other.input
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
        output += other.output
        longContextSurcharge += other.longContextSurcharge
        hasKnownRate = hasKnownRate && other.hasKnownRate
    }

    static let unpriced = CostBreakdown(hasKnownRate: false)
}

// MARK: - Catalog

/// A set of model rates. The same shape is used for the bundled table, the
/// remote refresh, and the user's own overrides.
struct PricingCatalog: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var displayName: String?
        var rate: ModelRate
    }

    var schema: Int = PricingCatalog.currentSchema
    /// Informational only - shown in Settings as "rates as of".
    var updated: String?
    var entries: [Entry]

    static let currentSchema = 1

    /// Sanity limits. A garbled or tampered catalog must not be able to produce
    /// an absurd total, so anything outside these bounds rejects the whole file.
    private static let maxEntries = 500
    private static let maxRatePerMTok = 10_000.0
    private static let maxMultiplier = 10.0

    /// Decode and sanity-check. Returns nil rather than throwing - every caller
    /// treats a bad catalog as "keep what we already have".
    static func validated(_ data: Data) -> PricingCatalog? {
        guard let catalog = try? JSONDecoder().decode(PricingCatalog.self, from: data) else { return nil }
        return catalog.isValid ? catalog : nil
    }

    var isValid: Bool {
        // A newer build may add fields this one would silently drop.
        guard schema <= Self.currentSchema else { return false }
        guard (1...Self.maxEntries).contains(entries.count) else { return false }
        return entries.allSatisfy(\.isValid)
    }
}

private extension PricingCatalog.Entry {
    var isValid: Bool {
        guard !id.isEmpty else { return false }
        guard Self.inRange(rate.input), Self.inRange(rate.output) else { return false }
        if let read = rate.cacheReadPerMTok, !Self.inRange(read, allowingZero: true) { return false }
        if let premium = rate.longContext {
            guard premium.thresholdInputTokens > 0,
                  Self.isMultiplier(premium.inputMultiplier),
                  Self.isMultiplier(premium.outputMultiplier)
            else { return false }
        }
        return true
    }

    private static func inRange(_ v: Double, allowingZero: Bool = false) -> Bool {
        v.isFinite && (allowingZero ? v >= 0 : v > 0) && v <= 10_000
    }

    private static func isMultiplier(_ v: Double) -> Bool {
        v.isFinite && v >= 1 && v <= 10
    }
}

// MARK: - Pricer

/// Resolves a model id to a rate and prices a single response.
///
/// Immutable and built once per catalog generation: layering, prefix matching,
/// and the long-context rule all live here so no call site does string surgery
/// or rate arithmetic of its own.
struct Pricer: Sendable {
    private let exact: [String: PricingCatalog.Entry]
    /// Entries sorted by id length, longest first, so the first `hasPrefix` hit
    /// is the longest-prefix match. Sorting once here replaces a filter+max
    /// allocation that would otherwise run on every record of every recompute.
    private let byLengthDesc: [PricingCatalog.Entry]

    /// - Parameter layers: catalogs in *ascending* priority. A later layer
    ///   replaces an earlier layer's entry for the same id, per entry, so a
    ///   partial override does not hide the rest of the table.
    init(layers: [PricingCatalog]) {
        var merged: [String: PricingCatalog.Entry] = [:]
        for layer in layers {
            for entry in layer.entries {
                var entry = entry
                // A higher layer usually only carries rates. Inheriting the name
                // it did not set keeps a user override from blanking the label.
                if entry.displayName == nil { entry.displayName = merged[entry.id]?.displayName }
                merged[entry.id] = entry
            }
        }
        exact = merged
        byLengthDesc = merged.values.sorted {
            $0.id.count != $1.id.count ? $0.id.count > $1.id.count : $0.id < $1.id
        }
    }

    private func entry(for canonicalID: String) -> PricingCatalog.Entry? {
        if let hit = exact[canonicalID] { return hit }
        return byLengthDesc.first { canonicalID.hasPrefix($0.id) }
    }

    /// - Parameter model: a raw logged id; any `[1m]` suffix is ignored here,
    ///   because the tier selects a premium, not a different table entry.
    func rate(for model: String) -> ModelRate? {
        entry(for: ContextTier.split(model).id)?.rate
    }

    /// A short label for the UI, keeping any context-tier suffix visible.
    func displayName(for model: String) -> String {
        let (id, _) = ContextTier.split(model)
        let suffix = String(model.dropFirst(id.count))
        let base = entry(for: id)?.displayName ?? Self.prettify(id)
        return suffix.isEmpty ? base : "\(base) \(suffix)"
    }

    /// Best-effort label for a model with no catalog entry.
    private static func prettify(_ id: String) -> String {
        let trimmed = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
        return trimmed.isEmpty ? id : trimmed
    }

    // MARK: Cost

    func cost(of record: UsageRecord) -> CostBreakdown {
        guard let rate = entry(for: record.canonicalModel)?.rate else { return .unpriced }
        return Self.cost(
            rate: rate,
            tier: record.contextTier,
            input: record.inputTokens,
            cacheWrite5m: record.cacheWrite5mTokens,
            cacheWrite1h: record.cacheWrite1hTokens,
            cacheRead: record.cacheReadTokens,
            output: record.outputTokens
        )
    }

    /// Cost for one response's token counts.
    ///
    /// Three things about the long-context premium are easy to get wrong:
    /// it multiplies the *whole* request rather than only the excess above the
    /// threshold; cache reads count toward the threshold; and the input
    /// multiplier applies to cache writes and cache reads too, since those are
    /// input-side tokens. Only `output` takes the output multiplier.
    static func cost(
        rate: ModelRate,
        tier: ContextTier = .standard,
        input: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        cacheRead: Int,
        output: Int
    ) -> CostBreakdown {
        let perToken = 1.0 / 1_000_000.0
        var out = CostBreakdown()
        out.input = Double(input) * rate.input * perToken
        out.cacheWrite5m = Double(cacheWrite5m) * rate.cacheWrite5mRate * perToken
        out.cacheWrite1h = Double(cacheWrite1h) * rate.cacheWrite1hRate * perToken
        out.cacheRead = Double(cacheRead) * rate.cacheReadRate * perToken
        out.output = Double(output) * rate.output * perToken

        guard tier == .oneMillion, let premium = rate.longContext else { return out }
        let promptTokens = input + cacheWrite5m + cacheWrite1h + cacheRead
        guard promptTokens > premium.thresholdInputTokens else { return out }

        let inputSide = out.input + out.cacheWrite5m + out.cacheWrite1h + out.cacheRead
        out.longContextSurcharge =
            inputSide * (premium.inputMultiplier - 1)
            + out.output * (premium.outputMultiplier - 1)
        return out
    }
}

// MARK: - Bundled catalog

enum Pricing {
    /// Rates compiled into the app: the guaranteed floor under the remote
    /// refresh and the user's overrides.
    ///
    /// History matters here. An "All time" view over multi-year logs contains
    /// model ids that the API retired long ago, and a missing entry silently
    /// prices that usage at $0. Matching is exact first, then longest-prefix, so
    /// dated snapshots such as `claude-haiku-4-5-20251001` resolve to their base
    /// entry - which also means related ids must be added *together*, or a
    /// dated `claude-sonnet-4-5-...` would fall through to `claude-sonnet-4`.
    static let bundled = PricingCatalog(
        updated: "2026-09-11",
        entries: [
            // Current generation.
            entry("claude-fable-5-1",  "Fable 5.1",  input: 10, output: 50, cacheRead: 0.25),
            entry("claude-mythos-5-1", "Mythos 5.1", input: 10, output: 50, cacheRead: 0.25),
            entry("claude-fable-5",    "Fable 5",    input: 10, output: 50),
            entry("claude-mythos-5",   "Mythos 5",   input: 10, output: 50),
            entry("claude-opus-5",     "Opus 5",     input: 5,  output: 25),
            entry("claude-opus-4-8",   "Opus 4.8",   input: 5,  output: 25),
            entry("claude-opus-4-7",   "Opus 4.7",   input: 5,  output: 25),
            entry("claude-opus-4-6",   "Opus 4.6",   input: 5,  output: 25),
            entry("claude-sonnet-5",   "Sonnet 5",   input: 2,  output: 10),
            entry("claude-sonnet-4-6", "Sonnet 4.6", input: 3,  output: 15),
            entry("claude-haiku-4-5",  "Haiku 4.5",  input: 1,  output: 5),

            // Retired, but still present in older logs.
            entry("claude-opus-4-5",   "Opus 4.5",   input: 5,  output: 25),
            entry("claude-opus-4-1",   "Opus 4.1",   input: 15, output: 75),
            entry("claude-opus-4-0",   "Opus 4",     input: 15, output: 75),
            entry("claude-opus-4-20250514", "Opus 4", input: 15, output: 75),

            // Sonnet 4 and 4.5 are the only models that ever charged a
            // long-context premium. Both spellings of each are listed because
            // longest-prefix matching would otherwise route a dated 4.5
            // snapshot to the 4.0 entry.
            entry("claude-sonnet-4-5", "Sonnet 4.5", input: 3, output: 15,
                  longContext: .sonnet1MBeta),
            entry("claude-sonnet-4-0", "Sonnet 4",   input: 3, output: 15,
                  longContext: .sonnet1MBeta),
            entry("claude-sonnet-4-20250514", "Sonnet 4", input: 3, output: 15,
                  longContext: .sonnet1MBeta),

            entry("claude-3-7-sonnet", "Sonnet 3.7", input: 3,    output: 15),
            entry("claude-3-5-sonnet", "Sonnet 3.5", input: 3,    output: 15),
            entry("claude-3-5-haiku",  "Haiku 3.5",  input: 0.80, output: 4),
            entry("claude-3-opus",     "Opus 3",     input: 15,   output: 75),
            entry("claude-3-haiku",    "Haiku 3",    input: 0.25, output: 1.25),
        ]
    )

    private static func entry(
        _ id: String,
        _ name: String,
        input: Double,
        output: Double,
        cacheRead: Double? = nil,
        longContext: LongContextPremium? = nil
    ) -> PricingCatalog.Entry {
        PricingCatalog.Entry(
            id: id,
            displayName: name,
            rate: ModelRate(
                input: input,
                output: output,
                cacheReadPerMTok: cacheRead,
                longContext: longContext
            )
        )
    }
}
