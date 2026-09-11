import Foundation

/// `TokenCounter --test` runs the suite and exits non-zero on failure.
///
/// The checks live in the executable because XCTest and swift-testing both ship
/// with Xcode, and this package targets a Command Line Tools install.
enum SelfTest {
    static let flag = "--test"

    // MARK: - Harness

    private final class Recorder {
        var passed = 0
        var failures: [String] = []
        var currentSection = ""

        func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "", line: UInt) {
            if ok {
                passed += 1
            } else {
                let extra = detail()
                failures.append("  \(currentSection) › \(what) (line \(line))"
                                + (extra.isEmpty ? "" : "\n      \(extra)"))
            }
        }
    }

    private static let r = Recorder()

    private static func section(_ name: String) {
        r.currentSection = name
        print("• \(name)")
    }

    private static func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
        r.check(ok, what, line: line)
    }

    private static func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
        r.check(actual == expected, what, "expected \(expected), got \(actual)", line: line)
    }

    /// Tolerance is 1e-6 rather than 1e-9: aggregate totals sum tens of
    /// thousands of per-record Doubles, and that drifts well past 1e-9.
    private static func close(
        _ actual: Double, _ expected: Double, _ what: String,
        tolerance: Double = 1e-6, line: UInt = #line
    ) {
        r.check(abs(actual - expected) <= tolerance, what,
                "expected \(expected), got \(actual)", line: line)
    }

    /// Runs on the main actor and lets `dispatchMain` service it, rather than
    /// blocking the calling thread on a semaphore - parts of the suite touch
    /// main-actor types, and waiting here would deadlock against them.
    static func runAndExit() -> Never {
        Task { @MainActor in
            await runAll()
            report()
        }
        dispatchMain()
    }

    @MainActor
    private static func report() -> Never {
        print("")
        if r.failures.isEmpty {
            print("PASSED — \(r.passed) checks")
            exit(0)
        }
        print("FAILED — \(r.failures.count) of \(r.passed + r.failures.count) checks")
        for failure in r.failures { print(failure) }
        exit(1)
    }

    @MainActor
    private static func runAll() async {
        pricing()
        costArithmetic()
        longContextPremium()
        pricingLayers()
        dedupRule()
        rangeResolution()
        granularity()
        aggregation()
        projectLabels()
        colorStability()
        formatting()
        await scanner()
        await archiveTests()
        budgetTests()
    }

    // MARK: - Budgets

    @MainActor
    private static func budgetTests() {
        section("Budgets")

        // A scratch suite, so the suite never overwrites the user's real limits
        // or suppresses an alert they have not seen.
        let suite = UserDefaults(suiteName: "tokencounter-selftest-\(UUID().uuidString)")!
        let now = date("2026-09-11T12:00:00-05:00")

        func store(daily: Double? = nil, monthly: Double? = nil) -> BudgetStore {
            let b = BudgetStore(defaults: suite)
            b.resetNotificationHistory()
            b.dailyLimit = daily
            b.monthlyLimit = monthly
            return b
        }

        // Progress.
        let b = store(daily: 10, monthly: 200)
        b.update(dailySpend: 2.5, monthlySpend: 50, now: now)
        close(b.fraction(for: .daily) ?? -1, 0.25, "daily fraction")
        close(b.fraction(for: .monthly) ?? -1, 0.25, "monthly fraction")
        expect(b.isActive, "a store with limits is active")

        let none = store()
        expect(!none.isActive, "a store with no limits is inactive")
        expect(none.fraction(for: .daily) == nil, "no limit means no fraction")
        expect(none.mostPressing == nil, "nothing to show without a limit")

        // The period nearest its limit is the one worth surfacing.
        let pressing = store(daily: 10, monthly: 100)
        pressing.update(dailySpend: 1, monthlySpend: 90, now: now)
        equal(pressing.mostPressing?.period, .monthly, "the closer period is the pressing one")

        // Threshold selection. Only the higher level fires, so crossing 100%
        // does not also announce 80%.
        let quiet = store(daily: 10)
        quiet.update(dailySpend: 7.9, monthlySpend: 0, now: now)
        equal(quiet.evaluate(.daily, now: now), nil, "below the warning threshold, nothing fires")

        let warn = store(daily: 10)
        warn.update(dailySpend: 8.0, monthlySpend: 0, now: now)
        equal(warn.evaluate(.daily, now: now), .warning, "at exactly the threshold, a warning fires")

        let over = store(daily: 10)
        over.update(dailySpend: 10.0, monthlySpend: 0, now: now)
        equal(over.evaluate(.daily, now: now), .exceeded, "at the limit, exceeded fires")
        equal(over.evaluate(.daily, now: now), nil, "and it does not fire twice in one period")

        // Rolling into the next day lets it fire again; the same day does not.
        let rollover = store(daily: 10)
        rollover.update(dailySpend: 12, monthlySpend: 0, now: now)
        equal(rollover.evaluate(.daily, now: now), .exceeded, "first alert of the day")
        equal(rollover.evaluate(.daily, now: date("2026-09-11T23:00:00-05:00")), nil,
              "later the same day stays quiet")
        equal(rollover.evaluate(.daily, now: date("2026-09-12T09:00:00-05:00")), .exceeded,
              "the next day can alert again")

        // The dedupe key is persisted, so a relaunch does not re-fire.
        let reopened = BudgetStore(defaults: suite)
        reopened.dailyLimit = 10
        reopened.update(dailySpend: 12, monthlySpend: 0, now: date("2026-09-12T10:00:00-05:00"))
        equal(reopened.evaluate(.daily, now: date("2026-09-12T10:00:00-05:00")), nil,
              "a relaunch does not repeat an alert already seen")

        // Raising a limit the user already blew past can be re-armed by hand.
        reopened.resetNotificationHistory()
        equal(reopened.evaluate(.daily, now: date("2026-09-12T10:00:00-05:00")), .exceeded,
              "resetting the history lets it alert again")

        // A zero or absent limit must never divide by zero.
        let zero = store(daily: 0)
        zero.update(dailySpend: 5, monthlySpend: 0, now: now)
        expect(zero.fraction(for: .daily) == nil, "a zero limit yields no fraction")
        equal(zero.evaluate(.daily, now: now), nil, "a zero limit never alerts")

        suite.removePersistentDomain(forName: suite.description)
    }

    // MARK: - Archive

    @MainActor
    private static func archiveTests() async {
        section("Archive")

        // Months are UTC, so a record does not move between files when the user
        // travels. 23:00 on Sep 30 in Chicago is already October in UTC.
        equal(UsageArchive.monthKey(for: date("2026-09-30T23:00:00-05:00")), "2026-10",
              "month keys are UTC, not local")
        equal(UsageArchive.monthKey(for: date("2026-09-30T12:00:00-05:00")), "2026-09",
              "midday stays in its own month")

        guard let root = try? makeTempDir() else {
            expect(false, "create temp dir")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let sept = date("2026-09-05T12:00:00-05:00")
        let aug = date("2026-08-05T12:00:00-05:00")

        // Round trip, and the lock that stops two copies fighting over a month.
        do {
            let dir = root.appendingPathComponent("roundtrip", isDirectory: true)
            let archive = UsageArchive(directory: dir, enabled: true)
            let merged = archive.integrate(live: [
                makeRecord(id: "a", at: sept, output: 100),
                makeRecord(id: "b", at: aug, output: 200),
            ])
            equal(merged.count, 2, "both records come back")
            equal(merged.first?.id, "b", "merged records are sorted by time")
            expect(archive.hasPendingWrites, "two new months are pending")
            archive.flush()
            expect(!archive.hasPendingWrites, "flush clears the pending set")

            equal(UsageArchive.load(file: dir.appendingPathComponent("2026-09.json"))?.count, 1,
                  "September round-trips through its own file")
            equal(UsageArchive.load(file: dir.appendingPathComponent("2026-08.json"))?.count, 1,
                  "August is a separate file")

            // Re-integrating identical records must not dirty anything.
            _ = archive.integrate(live: [makeRecord(id: "a", at: sept, output: 100)])
            expect(!archive.hasPendingWrites, "an unchanged month is not rewritten")

            // A second instance can read the same archive but must not write it.
            let second = UsageArchive(directory: dir, enabled: true)
            equal(second.recordCount, 2, "a second instance loads the same history")
            expect(second.isReadOnly, "the second instance does not take the write lock")
        }

        // The supersedes rule has to survive the merge in both directions: a
        // rotated log that is re-read may yield only an early snapshot of a
        // message the archive already holds complete.
        do {
            let partial = makeRecord(id: "m", at: sept, output: 1)
            let complete = makeRecord(id: "m", at: sept, output: 400)

            let a = UsageArchive(directory: root.appendingPathComponent("merge-a"), enabled: true)
            _ = a.integrate(live: [complete])
            equal(a.integrate(live: [partial]).first?.outputTokens, 400,
                  "a complete archived snapshot survives a re-read partial")

            let b = UsageArchive(directory: root.appendingPathComponent("merge-b"), enabled: true)
            _ = b.integrate(live: [partial])
            equal(b.integrate(live: [complete]).first?.outputTokens, 400,
                  "and a later complete snapshot still wins")
        }

        // History survives the logs disappearing entirely.
        do {
            let dir = root.appendingPathComponent("survives", isDirectory: true)
            let first = UsageArchive(directory: dir, enabled: true)
            _ = first.integrate(live: [makeRecord(id: "gone", at: sept, output: 100)])
            first.flush()

            let reopened = UsageArchive(directory: dir, enabled: true)
            equal(reopened.integrate(live: []).count, 1,
                  "a record whose log file is gone is still counted")
        }

        // Damaged files: refused, quarantined, and never fatal to their neighbours.
        do {
            let dir = root.appendingPathComponent("corrupt", isDirectory: true)
            AppPaths.ensure(dir)
            let good = UsageArchive(directory: dir, enabled: true)
            _ = good.integrate(live: [makeRecord(id: "ok", at: sept, output: 100)])
            good.flush()

            let truncated = dir.appendingPathComponent("2026-07.json")
            try? Data(#"{"schema":1,"month":"2026-07","records":[{"i":"x"#.utf8).write(to: truncated)
            let future = dir.appendingPathComponent("2026-06.json")
            try? Data(#"{"schema":99,"month":"2026-06","records":[]}"#.utf8).write(to: future)

            equal(UsageArchive.load(file: truncated), nil, "a truncated file loads as nil, not a crash")
            equal(UsageArchive.load(file: future), nil, "a future schema is refused")

            let reopened = UsageArchive(directory: dir, enabled: true)
            equal(reopened.recordCount, 1, "one damaged month does not lose the others")
            equal(reopened.quarantined.count, 2, "both damaged months are quarantined")
            expect(!FileManager.default.fileExists(atPath: truncated.path),
                   "the damaged file is moved aside")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            expect(names.contains { $0.contains("corrupt-") },
                   "a damaged month is quarantined, never deleted")
        }

        // The whole reason the archive stores tokens and not dollars.
        do {
            let archive = UsageArchive(directory: root.appendingPathComponent("reprice"), enabled: true)
            let merged = archive.integrate(live: [costing(3, id: "p", at: sept)])
            let interval = DateInterval(start: aug, end: date("2026-10-01T00:00:00-05:00"))
            close(build(merged, interval, pricer: flat).totals.cost, 3, "archived usage prices")
            close(build(merged, interval, pricer: flatDoubled).totals.cost, 6,
                  "archived usage reprices under a new catalog")
        }

        // Disabled, the archive is a pass-through and touches no disk.
        do {
            let dir = root.appendingPathComponent("disabled", isDirectory: true)
            let archive = UsageArchive(directory: dir, enabled: false)
            equal(archive.integrate(live: [makeRecord(id: "z", at: sept)]).count, 1,
                  "disabled, live records pass straight through")
            archive.flush()
            expect(!FileManager.default.fileExists(atPath: dir.path),
                   "disabled, nothing is written to disk")
        }
    }

    // MARK: - Pricers

    /// The rates the app ships with.
    private static let bundled = Pricer(layers: [Pricing.bundled])

    /// $1 per million tokens, in and out, so a test can name a dollar figure and
    /// get it back. See `costing(_:)`.
    private static let flat = Pricer(layers: [PricingCatalog(entries: [
        PricingCatalog.Entry(id: "flat", displayName: "Flat", rate: ModelRate(input: 1, output: 1)),
    ])])

    /// Twice `flat`, for checking that repricing is a pure function of the rates.
    private static let flatDoubled = Pricer(layers: [PricingCatalog(entries: [
        PricingCatalog.Entry(id: "flat", displayName: "Flat", rate: ModelRate(input: 2, output: 2)),
    ])])

    // MARK: - Pricing

    private static func pricing() {
        section("Pricing")

        equal(bundled.rate(for: "claude-opus-5")?.input, 5, "opus 5 input rate")
        equal(bundled.rate(for: "claude-opus-5")?.output, 25, "opus 5 output rate")
        equal(bundled.rate(for: "claude-sonnet-5")?.input, 2, "sonnet 5 input rate")
        equal(bundled.rate(for: "claude-sonnet-4-6")?.input, 3, "sonnet 4.6 input rate")
        equal(bundled.rate(for: "claude-haiku-4-5")?.output, 5, "haiku 4.5 output rate")

        // The context-tier suffix must not defeat table matching.
        equal(ContextTier.split("claude-opus-5[1m]").id, "claude-opus-5", "strips [1m] suffix")
        equal(ContextTier.split("claude-opus-5[1m]").tier, .oneMillion, "reads the 1m tier")
        equal(ContextTier.split("claude-opus-5").tier, .standard, "no suffix is the standard tier")
        equal(bundled.rate(for: "claude-opus-5[1m]"), bundled.rate(for: "claude-opus-5"),
              "[1m] resolves to the same table entry")
        equal(bundled.displayName(for: "claude-opus-5[1m]"), "Opus 5 [1m]", "[1m] shown in label")

        // A dated snapshot falls back to its base model.
        equal(bundled.rate(for: "claude-haiku-4-5-20251001")?.input, 1, "dated snapshot rate")
        equal(bundled.displayName(for: "claude-haiku-4-5-20251001"), "Haiku 4.5", "dated snapshot label")

        // Longest prefix wins: fable-5-1 must not resolve as fable-5.
        equal(bundled.rate(for: "claude-fable-5-1")?.cacheReadPerMTok, 0.25, "fable 5.1 cache-read override")
        equal(bundled.rate(for: "claude-mythos-5-1")?.cacheReadPerMTok, 0.25, "mythos 5.1 matches fable 5.1")
        equal(bundled.rate(for: "claude-fable-5")?.cacheReadPerMTok, nil, "fable 5 has no override")
        close(bundled.rate(for: "claude-fable-5")?.cacheReadRate ?? 0, 1.0, "fable 5 cache read = 0.1x input")

        // Historical models: an "All time" view over old logs contains these, and
        // a missing entry silently prices that usage at zero.
        equal(bundled.rate(for: "claude-opus-4-5-20251101")?.input, 5, "opus 4.5 snapshot")
        equal(bundled.rate(for: "claude-opus-4-1-20250805")?.input, 15, "opus 4.1")
        equal(bundled.rate(for: "claude-opus-4-20250514")?.input, 15, "opus 4 dated id")
        equal(bundled.rate(for: "claude-sonnet-4-20250514")?.input, 3, "sonnet 4 dated id")
        equal(bundled.rate(for: "claude-3-7-sonnet-20250219")?.input, 3, "sonnet 3.7")
        equal(bundled.rate(for: "claude-3-5-sonnet-20241022")?.input, 3, "sonnet 3.5 (Oct)")
        equal(bundled.rate(for: "claude-3-5-sonnet-20240620")?.input, 3, "sonnet 3.5 (Jun)")
        equal(bundled.rate(for: "claude-3-5-haiku-20241022")?.input, 0.80, "haiku 3.5")
        equal(bundled.rate(for: "claude-3-opus-20240229")?.input, 15, "opus 3")
        equal(bundled.rate(for: "claude-3-haiku-20240307")?.input, 0.25, "haiku 3")

        // Sonnet 4 and 4.5 share a prefix, so a dated 4.5 snapshot would silently
        // take 4.0's entry if only one of the two were listed.
        equal(bundled.rate(for: "claude-sonnet-4-5-20250929")?.input, 3, "dated sonnet 4.5 resolves")
        expect(bundled.rate(for: "claude-sonnet-4-5")?.longContext != nil, "sonnet 4.5 declares a premium")
        expect(bundled.rate(for: "claude-sonnet-4-20250514")?.longContext != nil, "sonnet 4 declares a premium")
        // Haiku 3 and Haiku 3.5 must not collide either.
        expect(bundled.rate(for: "claude-3-5-haiku-20241022")?.input != 0.25, "haiku 3.5 is not haiku 3")

        expect(bundled.rate(for: "gpt-4") == nil, "unknown vendor has no rate")
        expect(bundled.rate(for: "claude-nonexistent-9") == nil, "unknown claude model has no rate")
        equal(bundled.cost(of: makeRecord(model: "claude-nonexistent-9")).hasKnownRate, false,
              "an unknown model is flagged as unpriced")
        close(bundled.cost(of: makeRecord(model: "claude-nonexistent-9")).total, 0,
              "an unknown model costs zero")
    }

    private static func costArithmetic() {
        section("Cost arithmetic")

        let rate = ModelRate(input: 5, output: 25)
        let all = Pricer.cost(rate: rate, input: 1_000_000, cacheWrite5m: 1_000_000,
                              cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // 5.00 input + 6.25 (1.25x) + 10.00 (2x) + 0.50 (0.1x) + 25.00 output
        close(all.input, 5.0, "input component")
        close(all.cacheWrite5m, 6.25, "5-minute cache write is 1.25x input")
        close(all.cacheWrite1h, 10.0, "1-hour cache write is 2x input")
        close(all.cacheRead, 0.5, "cache read is 0.1x input")
        close(all.output, 25.0, "output component")
        close(all.total, 46.75, "all five token classes priced correctly")
        close(all.total,
              all.input + all.cacheWrite5m + all.cacheWrite1h + all.cacheRead + all.output
                  + all.longContextSurcharge,
              "components sum to the total")
        // A cache-read token is worth ~1/50th of an output token here, which is
        // the whole reason a flat token count is not an invoice.
        expect(all.cacheRead / all.total < 0.02, "cache reads are a rounding error next to output")

        let overridden = ModelRate(input: 10, output: 50, cacheReadPerMTok: 0.25)
        close(Pricer.cost(rate: overridden, input: 0, cacheWrite5m: 0, cacheWrite1h: 0,
                          cacheRead: 4_000_000, output: 0).total,
              1.0, "cache-read override beats the 0.1x default")

        close(Pricer.cost(rate: rate, input: 0, cacheWrite5m: 0, cacheWrite1h: 0,
                          cacheRead: 0, output: 0).total,
              0, "zero tokens cost nothing")
    }

    // MARK: - Long-context premium

    /// Sonnet 4 and Sonnet 4.5 under the 1M-context beta billed the *entire*
    /// request at 2x input / 1.5x output once total input passed 200K. Every
    /// expected value below is derived, not copied.
    private static func longContextPremium() {
        section("Long-context premium")

        func sonnet(
            tier: ContextTier,
            input: Int = 0, cacheWrite5m: Int = 0, cacheRead: Int = 0, output: Int = 0
        ) -> CostBreakdown {
            bundled.cost(of: makeRecord(
                model: tier == .oneMillion ? "claude-sonnet-4-5[1m]" : "claude-sonnet-4-5",
                input: input, cacheWrite5m: cacheWrite5m, cacheRead: cacheRead, output: output
            ))
        }

        // Rates in play: input $3, output $15, cache read 0.1x = $0.30/MTok.
        let inRate = 3.0 / 1_000_000, outRate = 15.0 / 1_000_000, readRate = 0.30 / 1_000_000

        // The threshold is strict: exactly 200K is still standard pricing.
        close(sonnet(tier: .oneMillion, input: 200_000).total,
              200_000 * inRate, "at exactly 200K input there is no premium")
        close(sonnet(tier: .oneMillion, input: 200_001).total,
              200_001 * inRate * 2, "one token past 200K doubles the input side")
        close(sonnet(tier: .oneMillion, input: 200_001).longContextSurcharge,
              200_001 * inRate, "the surcharge is reported separately from the base")

        // Without the suffix the premium never applies, however large the request.
        close(sonnet(tier: .standard, input: 1_000_000).total,
              1_000_000 * inRate, "no [1m] suffix means no premium at any size")

        // Cache reads count toward the threshold *and* take the input multiplier.
        close(sonnet(tier: .oneMillion, cacheRead: 300_000).total,
              300_000 * readRate * 2, "cache reads alone can cross the threshold")
        close(sonnet(tier: .oneMillion, input: 150_000, cacheRead: 60_000).total,
              (150_000 * inRate + 60_000 * readRate) * 2,
              "input and cache reads cross the threshold together")

        // Input 2x and output 1.5x compose on one request.
        close(sonnet(tier: .oneMillion, input: 250_000, output: 1_000_000).total,
              250_000 * inRate * 2 + 1_000_000 * outRate * 1.5,
              "input 2x and output 1.5x apply together")

        // Output alone never crosses the threshold - it is an input-side test.
        close(sonnet(tier: .oneMillion, input: 1_000, output: 5_000_000).total,
              1_000 * inRate + 5_000_000 * outRate,
              "a huge output with a small prompt is not a long-context request")

        // No currently-served model carries a premium.
        expect(bundled.rate(for: "claude-opus-5")?.longContext == nil, "opus 5 declares no premium")
        expect(bundled.rate(for: "claude-sonnet-4-6")?.longContext == nil, "sonnet 4.6 declares no premium")
        close(bundled.cost(of: makeRecord(model: "claude-opus-5[1m]", input: 900_000, output: 0)).total,
              900_000 * 5.0 / 1_000_000, "a current model at 900K has no premium")

        // The tier is parsed once, at record construction.
        equal(makeRecord(model: "claude-opus-5[1m]").contextTier, .oneMillion, "record stores the tier")
        equal(makeRecord(model: "claude-opus-5[1m]").canonicalModel, "claude-opus-5",
              "record stores the canonical id")
        equal(makeRecord(model: "claude-opus-5[1m]").model, "claude-opus-5[1m]",
              "record keeps the raw id for display and rollup")
    }

    // MARK: - Layering

    private static func pricingLayers() {
        section("Pricing layers")

        func catalog(_ id: String, input: Double, output: Double, name: String? = nil) -> PricingCatalog {
            PricingCatalog(entries: [
                PricingCatalog.Entry(id: id, displayName: name,
                                     rate: ModelRate(input: input, output: output)),
            ])
        }

        let base = Pricing.bundled
        let remote = catalog("claude-opus-5", input: 7, output: 35)
        let override = catalog("claude-opus-5", input: 9, output: 45)

        equal(Pricer(layers: [base]).rate(for: "claude-opus-5")?.input, 5, "bundled is the floor")
        equal(Pricer(layers: [base, remote]).rate(for: "claude-opus-5")?.input, 7, "remote beats bundled")
        equal(Pricer(layers: [base, remote, override]).rate(for: "claude-opus-5")?.input, 9,
              "override beats remote")
        equal(Pricer(layers: [base, override]).rate(for: "claude-opus-5")?.input, 9,
              "override works without a remote layer")

        // Merging is per entry, so a one-model override must not hide the table.
        equal(Pricer(layers: [base, remote]).rate(for: "claude-haiku-4-5")?.input, 1,
              "a model absent from the remote falls through to bundled")
        equal(Pricer(layers: [base, override]).rate(for: "claude-sonnet-5")?.input, 2,
              "an override does not disturb other models")

        // A higher layer carrying only rates must not blank the label.
        equal(Pricer(layers: [base, override]).displayName(for: "claude-opus-5"), "Opus 5",
              "an unnamed override inherits the bundled display name")

        // Validation.
        func json(_ s: String) -> Data { Data(s.utf8) }
        expect(PricingCatalog.validated(json("not json at all")) == nil, "garbage is rejected")
        expect(PricingCatalog.validated(json(#"{"schema":1,"entries":[]}"#)) == nil,
               "an empty catalog is rejected")
        expect(PricingCatalog.validated(
            json(#"{"schema":1,"entries":[{"id":"m","rate":{"input":-1,"output":5}}]}"#)) == nil,
               "a negative rate is rejected")
        expect(PricingCatalog.validated(
            json(#"{"schema":99,"entries":[{"id":"m","rate":{"input":1,"output":5}}]}"#)) == nil,
               "a future schema is refused")
        expect(PricingCatalog.validated(
            json(#"{"schema":1,"entries":[{"id":"m","rate":{"input":1,"output":999999}}]}"#)) == nil,
               "an absurd rate is rejected")
        expect(PricingCatalog.validated(
            json(#"{"schema":1,"entries":[{"id":"","rate":{"input":1,"output":5}}]}"#)) == nil,
               "an empty model id is rejected")
        expect(PricingCatalog.validated(
            json(#"{"schema":1,"entries":[{"id":"m","rate":{"input":1,"output":5}}]}"#)) != nil,
               "a well-formed catalog is accepted")
        expect(Pricing.bundled.isValid, "the bundled catalog passes its own validation")

        // `--dump-catalog` publishes the bundled table as the remote catalog, so
        // that file has to survive its own validator and decode back unchanged.
        if let encoded = try? JSONEncoder().encode(Pricing.bundled) {
            let reloaded = PricingCatalog.validated(encoded)
            expect(reloaded != nil, "the published catalog passes validation")
            equal(reloaded?.entries.count, Pricing.bundled.entries.count,
                  "every entry survives the round trip")
            equal(reloaded, Pricing.bundled, "the published catalog round-trips exactly")
        } else {
            expect(false, "the bundled catalog encodes")
        }
    }

    // MARK: - Dedup

    private static func dedupRule() {
        section("Duplicate collapsing")

        let base = makeRecord(id: "msg_1", output: 10)
        let later = makeRecord(id: "msg_1", output: 400)

        expect(later.supersedes(base), "higher output supersedes")
        expect(!base.supersedes(later), "lower output does not supersede")

        // Thinking tokens are already inside output and must not inflate totals.
        let r = makeRecord(id: "m", input: 10, output: 1000, thinking: 400)
        equal(r.totalTokens, 1010, "thinking tokens are not added to the total")
    }

    // MARK: - Ranges

    private static var testCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private static func rangeResolution() {
        section("Range resolution")
        let cal = testCalendar
        let now = date("2026-09-10T15:30:00-05:00")

        if let today = RangePreset.today.interval(now: now, calendar: cal, custom: nil, dataBounds: nil) {
            equal(cal.component(.hour, from: today.start), 0, "today starts at local midnight")
            expect(today.contains(now), "today contains the current moment")
        } else {
            expect(false, "today resolves")
        }

        if let week = RangePreset.last7Days.interval(now: now, calendar: cal, custom: nil, dataBounds: nil) {
            let days = cal.dateComponents([.day], from: week.start, to: week.end).day ?? 0
            equal(days, 6, "last 7 days spans 7 inclusive days")
            expect(week.contains(now), "last 7 days contains now")
        } else {
            expect(false, "last 7 days resolves")
        }

        // A custom range carries a time of day, not just a date.
        let custom = DateInterval(start: date("2026-09-10T09:15:00-05:00"),
                                  end: date("2026-09-10T17:45:00-05:00"))
        if let resolved = RangePreset.custom.interval(now: now, calendar: cal, custom: custom, dataBounds: nil) {
            equal(cal.component(.hour, from: resolved.start), 9, "custom start keeps its hour")
            equal(cal.component(.minute, from: resolved.start), 15, "custom start keeps its minute")
            equal(cal.component(.hour, from: resolved.end), 17, "custom end keeps its hour")
            equal(cal.component(.minute, from: resolved.end), 45, "custom end keeps its minute")
        } else {
            expect(false, "custom range resolves")
        }

        let bounds = DateInterval(start: date("2026-01-01T00:00:00-06:00"),
                                  end: date("2026-09-01T00:00:00-05:00"))
        equal(RangePreset.allTime.interval(now: now, calendar: cal, custom: nil, dataBounds: bounds),
              bounds, "all time uses the data bounds")
        expect(RangePreset.allTime.interval(now: now, calendar: cal, custom: nil, dataBounds: nil) == nil,
               "all time is nil with no data")

        if let hour = RangePreset.last1Hour.interval(now: now, calendar: cal, custom: nil, dataBounds: nil) {
            close(hour.duration, 3600, "last hour spans an hour", tolerance: 1)
        } else {
            expect(false, "last hour resolves")
        }
    }

    private static func granularity() {
        section("Granularity")

        func autoUnit(hours: Double) -> BucketUnit {
            let start = date("2026-01-01T00:00:00-06:00")
            return GranularityChoice.automaticUnit(
                for: DateInterval(start: start, end: start.addingTimeInterval(hours * 3600))
            )
        }
        equal(autoUnit(hours: 12), .hour, "half a day charts hourly")
        equal(autoUnit(hours: 24 * 10), .day, "ten days charts daily")
        equal(autoUnit(hours: 24 * 200), .week, "200 days charts weekly")
        equal(autoUnit(hours: 24 * 900), .month, "900 days charts monthly")

        let start = date("2026-09-01T00:00:00-05:00")
        let week = DateInterval(start: start, end: start.addingTimeInterval(7 * 24 * 3600))
        equal(Aggregator.resolveUnit(choice: .hour, interval: week), .hour, "hourly kept over a week")
        equal(Aggregator.resolveUnit(choice: .day, interval: week), .day, "daily kept over a week")

        // Hourly over a year would be ~8,760 bars, so it must be coarsened.
        let year = DateInterval(start: start, end: start.addingTimeInterval(365 * 24 * 3600))
        expect(Aggregator.resolveUnit(choice: .hour, interval: year) != .hour,
               "hourly is coarsened over a year")
    }

    // MARK: - Aggregation

    private static func build(
        _ records: [UsageRecord],
        _ interval: DateInterval?,
        pricer: Pricer = flat,
        unit: BucketUnit = .day,
        sidechains: Bool = true
    ) -> Aggregates {
        Aggregator.build(
            records: records, interval: interval, unit: unit,
            includeSidechains: sidechains, pricer: pricer,
            colorMap: ModelColorMap(records: records), calendar: testCalendar
        )
    }

    private static func aggregation() {
        section("Aggregation")
        let september = DateInterval(start: date("2026-09-01T00:00:00-05:00"),
                                     end: date("2026-09-30T23:59:59-05:00"))
        let inRange = date("2026-09-05T12:00:00-05:00")
        let outOfRange = date("2026-08-01T12:00:00-05:00")

        let records = [costing(3, id: "a", at: inRange), costing(99, id: "b", at: outOfRange)]
        let agg = build(records, september)
        equal(agg.recordCount, 1, "out-of-range records are excluded")
        close(agg.totals.cost, 3, "totals reflect only the range")

        // Subagent filter.
        let mixed = [costing(1, id: "c", at: inRange),
                     costing(2, id: "d", at: inRange, sidechain: true)]
        close(build(mixed, september).totals.cost, 3, "subagents included when enabled")
        close(build(mixed, september, sidechains: false).totals.cost, 1, "subagents excluded when disabled")

        // Quiet days must still appear as buckets.
        let short = DateInterval(start: date("2026-09-01T00:00:00-05:00"),
                                 end: date("2026-09-05T23:59:59-05:00"))
        let single = [costing(1, id: "e", at: date("2026-09-01T12:00:00-05:00"))]
        let sparse = build(single, short)
        equal(sparse.bucketStarts.count, 5, "every day in range is a bucket")
        close(sparse.total(at: sparse.bucketStarts[0], metric: .cost), 1, "first bucket has the usage")
        close(sparse.total(at: sparse.bucketStarts[3], metric: .cost), 0, "empty bucket reads as zero")

        // Per-model, per-project and per-session rollups.
        let multi = [
            costing(5, id: "f", at: inRange, model: "claude-opus-5", project: "/a/one", session: "s1"),
            costing(2, id: "g", at: inRange, model: "claude-sonnet-5", project: "/a/one", session: "s1"),
            costing(1, id: "h", at: inRange, model: "claude-opus-5", project: "/a/two", session: "s2"),
        ]
        // `costing` prices under `flat`, so a pricer that knows every id is needed.
        let rollup = build(multi, september, pricer: multiPricer)
        close(rollup.totals.cost, 8, "grand total")
        equal(rollup.models.first?.id, "claude-opus-5", "models sorted by spend")
        close(rollup.models.first?.cost ?? 0, 6, "per-model total")
        equal(rollup.projects.first?.id, "/a/one", "project identity is the full path")
        equal(rollup.projects.first?.label, "one", "project label is the shortest unique suffix")
        close(rollup.projects.first?.cost ?? 0, 7, "per-project total")
        equal(rollup.projects.first?.models.count, 2, "per-project model breakdown")
        equal(rollup.sessions.count, 2, "sessions roll up separately")
        equal(rollup.sessions.first?.id, "s1", "sessions sorted by spend")
        close(rollup.sessions.first?.cost ?? 0, 7, "per-session total")

        // Two projects sharing a last segment must not merge.
        let colliding = [
            costing(1, id: "i", at: inRange, project: "/alice/work/api"),
            costing(2, id: "j", at: inRange, project: "/bob/personal/api"),
        ]
        equal(build(colliding, september).projects.count, 2,
              "same basename, different paths are two projects")

        repricing(september: september, at: inRange)
    }

    /// The invariant the whole pricing refactor exists to protect: a rate change
    /// is a recompute over the same records, never a re-parse.
    private static func repricing(september: DateInterval, at when: Date) {
        section("Repricing without rescan")

        let records = [costing(3, id: "k", at: when), costing(5, id: "l", at: when)]
        let cheap = build(records, september, pricer: flat)
        let dear = build(records, september, pricer: flatDoubled)

        close(cheap.totals.cost, 8, "baseline total")
        close(dear.totals.cost, cheap.totals.cost * 2, "doubling the rate doubles the total")
        equal(dear.recordCount, cheap.recordCount, "repricing does not change the record set")
        equal(dear.totals.total, cheap.totals.total, "repricing does not change token counts")
        equal(dear.bucketStarts, cheap.bucketStarts, "repricing does not change the buckets")

        // An unpriced model still contributes tokens, just no dollars.
        let unknown = [makeRecord(id: "m", at: when, model: "model-from-the-future", output: 1000)]
        let agg = build(unknown, september, pricer: flat)
        equal(agg.unpricedModels, ["model-from-the-future"], "unpriced model is reported")
        close(agg.totals.cost, 0, "unpriced model costs zero")
        equal(agg.totals.hasKnownRate, false, "unpriced total is flagged")
        equal(agg.totals.output, 1000, "unpriced model still contributes tokens")
    }

    // MARK: - Project labels

    private static func projectLabels() {
        section("Project labels")

        func label(_ paths: [String], _ path: String) -> String? {
            ProjectLabeler.labels(for: paths)[path]
        }

        equal(label(["/a/one"], "/a/one"), "one", "a unique basename stays short")
        equal(label(["/alice/work/api", "/bob/personal/api"], "/alice/work/api"), "work/api",
              "colliding basenames disambiguate at depth 2")
        equal(label(["/alice/work/api", "/bob/personal/api"], "/bob/personal/api"), "personal/api",
              "and so does the other one")
        equal(label(["/a/api", "/b/c/api"], "/b/c/api"), "c/api", "unequal depths disambiguate")
        equal(label(["/a/api", "/b/c/api"], "/a/api"), "a/api", "the shallower path too")
        equal(ProjectLabeler.labels(for: ["/x/p", "/y/p", "/z/p"]).values.sorted(),
              ["x/p", "y/p", "z/p"], "three-way collision")
        equal(label(["/x/w/p", "/y/w/p"], "/x/w/p"), "x/w/p", "collision at depth 2 goes to depth 3")
        equal(label([""], ""), ProjectLabeler.unknown, "an empty path is unknown")
        equal(label(["/p", "/y/p"], "/p"), "p", "a path that runs out of segments settles")
        equal(label(["/p", "/y/p"], "/y/p"), "y/p", "while the deeper one grows")
        equal(ProjectLabeler.labels(for: []).count, 0, "no paths, no labels")
    }

    private static func colorStability() {
        section("Series colors")

        let sept = date("2026-09-05T12:00:00-05:00")
        let aug = date("2026-08-05T12:00:00-05:00")
        // Colors rank by token volume, not spend, so a rate change cannot
        // repaint the legend.
        let all = [
            makeRecord(id: "i", at: aug, model: "claude-opus-5", output: 1_000_000),
            makeRecord(id: "j", at: sept, model: "claude-sonnet-5", output: 5_000),
        ]
        let map = ModelColorMap(records: all)
        expect(map.slot(for: "claude-opus-5") != map.slot(for: "claude-sonnet-5"),
               "distinct models get distinct slots")
        equal(map.slot(for: "claude-opus-5"), 0, "the heaviest model takes the first slot")

        // Slots come from the whole dataset, so narrowing the range cannot
        // repaint the series that remain.
        let narrowed = ModelColorMap(records: all)
        equal(narrowed.slot(for: "claude-sonnet-5"), map.slot(for: "claude-sonnet-5"),
              "slot is stable when the range narrows")

        // A ninth model folds into "Other" instead of inventing a ninth hue.
        let many = (0..<10).map { i in
            makeRecord(id: "k\(i)", at: sept, model: "model-\(i)", output: 1_000 - i)
        }
        let manyMap = ModelColorMap(records: many)
        equal(manyMap.namedModels.count, ModelColorMap.namedSeriesLimit, "named series are capped")
        equal(manyMap.seriesKey(for: "model-0"), "model-0", "top model keeps its own series")
        equal(manyMap.seriesKey(for: "model-9"), Aggregator.otherSeriesKey, "overflow folds into Other")

        let agg = Aggregator.build(
            records: many,
            interval: DateInterval(start: date("2026-09-01T00:00:00-05:00"),
                                   end: date("2026-09-30T00:00:00-05:00")),
            unit: .day, includeSidechains: true, pricer: flat,
            colorMap: manyMap, calendar: testCalendar
        )
        expect(agg.seriesKeys.contains(Aggregator.otherSeriesKey), "Other appears in the legend")
        expect(agg.seriesKeys.count <= ModelColorMap.namedSeriesLimit + 1, "at most 8 series drawn")
    }

    private static func formatting() {
        section("Formatting")
        equal(Fmt.tokens(812), "812", "small token counts are exact")
        equal(Fmt.tokens(1_500), "1.50K", "thousands")
        equal(Fmt.tokens(34_500), "34.5K", "tens of thousands")
        equal(Fmt.tokens(1_240_000), "1.24M", "millions")
        equal(Fmt.money(0), "$0.00", "zero cost")
        equal(Fmt.money(12.3456), "$12.35", "dollars round to cents")
        equal(Fmt.money(0.0123456), "$0.0123", "sub-dollar keeps precision")
        equal(Fmt.percent(0.5), "50%", "percentages")
    }

    // MARK: - Scanner (end to end, on a temp directory)

    private static func scanner() async {
        section("Log scanner")

        guard let root = try? makeTempDir() else {
            expect(false, "create temp dir")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Streaming snapshots of one response collapse to the final usage.
        do {
            let dir = root.appendingPathComponent("stream", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([
                logLine(id: "msg_1", cacheWrite: 1000, output: 1),
                logLine(id: "msg_1", cacheWrite: 1000, output: 120),
                logLine(id: "msg_1", cacheWrite: 1000, output: 400),
            ], to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.count, 1, "streaming snapshots collapse to one record")
            equal(result.records.first?.outputTokens, 400, "final snapshot's output wins")
            equal(result.duplicatesCollapsed, 2, "collapsed count is reported")
            expect(result.duplicatesCollapsed >= 0, "collapsed count is never negative")
        }

        // Distinct messages both count.
        do {
            let dir = root.appendingPathComponent("distinct", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_1", output: 100), logLine(id: "msg_2", output: 250)],
                            to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.count, 2, "distinct messages both count")
            equal(result.records.reduce(0) { $0 + $1.outputTokens }, 350, "outputs sum")
        }

        // A resumed session replays history into a second file.
        do {
            let dir = root.appendingPathComponent("crossfile", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_1", output: 400)], to: dir.appendingPathComponent("a.jsonl"))
            try? writeLines([logLine(id: "msg_1", output: 400)], to: dir.appendingPathComponent("b.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.count, 1, "duplicates across files collapse")
        }

        // Synthetic, errored, and zero-token entries are skipped.
        do {
            let dir = root.appendingPathComponent("skips", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([
                logLine(id: "msg_ok", output: 100),
                logLine(id: "msg_synth", model: "<synthetic>", output: 100),
                logLine(id: "msg_err", output: 100, apiError: true),
                logLine(id: "msg_zero", input: 0, output: 0),
            ], to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.map(\.id), ["msg_ok"], "only the billable entry survives")
        }

        // Nested subagent directories are walked.
        do {
            let dir = root.appendingPathComponent("nested", isDirectory: true)
            let deep = dir.appendingPathComponent("proj/session/subagents", isDirectory: true)
            try? FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_deep", output: 42)],
                            to: deep.appendingPathComponent("agent.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.map(\.id), ["msg_deep"], "nested directories are scanned")
        }

        // 1h-TTL cache writes cost 2x, not 1.25x.
        do {
            let dir = root.appendingPathComponent("ttl", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_ttl", model: "claude-opus-5",
                                     input: 0, cacheWrite: 1_000_000, output: 0, oneHourTTL: true)],
                            to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.first?.cacheWrite1hTokens, 1_000_000, "1h tokens tracked separately")
            close(bundled.cost(of: result.records[0]).total, 10.0, "1h cache write priced at 2x")
        }

        // The session id comes from the log filename, so spend traces to one
        // conversation.
        do {
            let dir = root.appendingPathComponent("session", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_1", output: 10)],
                            to: dir.appendingPathComponent("abc-123.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.first?.sessionID, "abc-123", "session id is the filename stem")
        }

        // A missing root is reported rather than crashing.
        do {
            let result = await LogScanner.scan(root: root.appendingPathComponent("nope"), previous: [:])
            equal(result.rootExists, false, "missing root is reported")
            equal(result.records.isEmpty, true, "missing root yields no records")
        }

        await cwdResolution(root: root)
        await incrementalScanner(root: root)
        await archiveRoundTrip()
    }

    /// Claude Code's directory names flatten `/` to `-`, which is not reversible.
    /// The real `cwd` from neighbouring entries is used instead.
    private static func cwdResolution(root: URL) async {
        section("cwd resolution")

        // Full path, not just the last two segments.
        do {
            let dir = root.appendingPathComponent("label", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_1", output: 10, cwd: "/Users/x/Documents/Clauding/TokenCounter")],
                            to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.first?.projectPath, "/Users/x/Documents/Clauding/TokenCounter",
                  "identity is the full working directory")
        }

        // A file with no cwd anywhere inherits its sibling's.
        do {
            let dir = root.appendingPathComponent("-Users-x-my-app", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_has", output: 10, cwd: "/Users/x/my-app")],
                            to: dir.appendingPathComponent("a.jsonl"))
            try? writeLines([logLine(id: "msg_none", output: 10, cwd: nil)],
                            to: dir.appendingPathComponent("b.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            let orphan = result.records.first { $0.id == "msg_none" }
            equal(orphan?.projectPath, "/Users/x/my-app", "a cwd-less entry inherits the sibling's cwd")
            expect(!(orphan?.projectPath.contains("/my/app") ?? true),
                   "a hyphenated project name is never split into path segments")
        }

        // The most common cwd wins over a one-off.
        do {
            let dir = root.appendingPathComponent("modal", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([
                logLine(id: "m1", output: 10, cwd: "/Users/x/main"),
                logLine(id: "m2", output: 10, cwd: "/Users/x/main"),
                logLine(id: "m3", output: 10, cwd: "/Users/x/stray"),
                logLine(id: "m4", output: 10, cwd: nil),
            ], to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.first { $0.id == "m4" }?.projectPath, "/Users/x/main",
                  "the most common cwd in the directory wins")
        }

        // With no cwd anywhere, the flattened name is used verbatim rather than
        // un-flattened into a fabricated path.
        do {
            let dir = root.appendingPathComponent("-Users-x-other-app", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([logLine(id: "msg_1", output: 10, cwd: nil)],
                            to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(result.records.first?.projectPath, "-Users-x-other-app",
                  "with no cwd anywhere the flattened name is used verbatim")
        }

        // A trailing slash must not split one project into two.
        do {
            let dir = root.appendingPathComponent("slash", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? writeLines([
                logLine(id: "s1", output: 10, cwd: "/Users/x/proj"),
                logLine(id: "s2", output: 10, cwd: "/Users/x/proj/"),
            ], to: dir.appendingPathComponent("a.jsonl"))

            let result = await LogScanner.scan(root: dir, previous: [:])
            equal(Set(result.records.map(\.projectPath)).count, 1,
                  "a trailing slash is normalised away")
        }
    }

    private static func incrementalScanner(root: URL) async {
        section("Incremental rescan")

        // Rescanning an unchanged tree is stable.
        do {
            let dir = root.appendingPathComponent("idem", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("a.jsonl")
            try? writeLines([logLine(id: "msg_1", output: 100)], to: file)

            let first = await LogScanner.scan(root: dir, previous: [:])
            let second = await LogScanner.scan(root: dir, previous: first.states)
            equal(second.records.count, 1, "rescan does not duplicate")
            equal(second.records.first?.outputTokens, 100, "rescan preserves usage")
        }

        // Appended lines are picked up from the stored offset.
        do {
            let dir = root.appendingPathComponent("append", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("a.jsonl")
            try? writeLines([logLine(id: "msg_1", output: 100)], to: file)

            let first = await LogScanner.scan(root: dir, previous: [:])
            equal(first.records.count, 1, "initial scan")

            try? appendText(logLine(id: "msg_2", output: 200) + "\n", to: file)
            let second = await LogScanner.scan(root: dir, previous: first.states)
            equal(second.records.count, 2, "appended record is picked up")
            equal(second.records.reduce(0) { $0 + $1.outputTokens }, 300, "appended usage sums")
        }

        // A later snapshot appended after the first pass supersedes, not adds.
        do {
            let dir = root.appendingPathComponent("supersede", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("a.jsonl")
            try? writeLines([logLine(id: "msg_1", output: 10)], to: file)

            let first = await LogScanner.scan(root: dir, previous: [:])
            try? appendText(logLine(id: "msg_1", output: 900) + "\n", to: file)
            let second = await LogScanner.scan(root: dir, previous: first.states)

            equal(second.records.count, 1, "late snapshot does not add a record")
            equal(second.records.first?.outputTokens, 900, "late snapshot supersedes")
        }

        // A half-written trailing line is deferred until complete - Claude Code
        // appends to these files while the app is reading them.
        do {
            let dir = root.appendingPathComponent("partial", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("a.jsonl")
            try? writeLines([logLine(id: "msg_1", output: 100)], to: file)

            let complete = logLine(id: "msg_2", output: 200)
            let cut = complete.index(complete.startIndex, offsetBy: complete.count / 2)
            try? appendText(String(complete[complete.startIndex..<cut]), to: file)

            let first = await LogScanner.scan(root: dir, previous: [:])
            equal(first.records.count, 1, "partial trailing line is not parsed")

            try? appendText(String(complete[cut...]) + "\n", to: file)
            let second = await LogScanner.scan(root: dir, previous: first.states)
            equal(second.records.count, 2, "completed line is picked up next pass")
        }

        // A truncated or rewritten file is re-read from the top.
        do {
            let dir = root.appendingPathComponent("truncate", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("a.jsonl")
            try? writeLines([logLine(id: "msg_1", output: 100), logLine(id: "msg_2", output: 200)], to: file)

            let first = await LogScanner.scan(root: dir, previous: [:])
            equal(first.records.count, 2, "initial scan of two records")

            try? writeLines([logLine(id: "msg_3", output: 300)], to: file)
            let second = await LogScanner.scan(root: dir, previous: first.states)
            equal(second.records.map(\.id), ["msg_3"], "truncated file is fully re-read")
        }
    }

    /// A record must survive a trip through the archive's encoding unchanged,
    /// including the context tier - which is recovered from the raw model id
    /// rather than stored separately, so the two cannot drift.
    private static func archiveRoundTrip() async {
        section("Record encoding")

        let original = makeRecord(
            id: "msg_x", at: date("2026-09-05T12:00:00-05:00"),
            model: "claude-sonnet-4-5[1m]", project: "/Users/x/proj", session: "sess-1",
            input: 412, cacheWrite5m: 7, cacheWrite1h: 9, cacheRead: 184_203,
            output: 901, thinking: 400, sidechain: true
        )

        guard let data = try? JSONEncoder().encode(original),
              let decoded = try? JSONDecoder().decode(UsageRecord.self, from: data)
        else {
            expect(false, "a record round-trips through JSON")
            return
        }

        equal(decoded, original, "every field survives the round trip")
        equal(decoded.contextTier, .oneMillion, "the context tier is recovered from the raw model id")
        equal(decoded.canonicalModel, "claude-sonnet-4-5", "the canonical id is recovered too")
        expect(!String(decoding: data, as: UTF8.self).contains("cost"),
               "no dollars are persisted, so history reprices under new rates")

        // Repricing archived history is the whole point of storing tokens only.
        close(bundled.cost(of: decoded).total, bundled.cost(of: original).total,
              "a decoded record prices identically")
    }

    // MARK: - Fixtures

    /// Knows every model the aggregation tests name, at `flat`'s $1/MTok, so a
    /// `costing(n)` record still costs exactly n dollars.
    private static let multiPricer = Pricer(layers: [PricingCatalog(entries: [
        PricingCatalog.Entry(id: "flat", displayName: "Flat", rate: ModelRate(input: 1, output: 1)),
        PricingCatalog.Entry(id: "claude-opus-5", displayName: "Opus 5", rate: ModelRate(input: 1, output: 1)),
        PricingCatalog.Entry(id: "claude-sonnet-5", displayName: "Sonnet 5", rate: ModelRate(input: 1, output: 1)),
    ])])

    /// A record that costs exactly `dollars` under `flat` and `multiPricer`:
    /// those price output at $1 per million tokens, so the token count is the
    /// dollar figure scaled by a million.
    private static func costing(
        _ dollars: Double,
        id: String = UUID().uuidString,
        at when: Date = Date(),
        model: String = "flat",
        project: String = "/Users/x/demo",
        session: String = "s1",
        sidechain: Bool = false
    ) -> UsageRecord {
        makeRecord(id: id, at: when, model: model, project: project, session: session,
                   input: 0, output: Int(dollars * 1_000_000), sidechain: sidechain)
    }

    private static func makeRecord(
        id: String = UUID().uuidString,
        at when: Date = Date(),
        model: String = "claude-sonnet-5",
        project: String = "/Users/x/demo",
        session: String = "s1",
        input: Int = 10,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0,
        output: Int = 100,
        thinking: Int = 0,
        sidechain: Bool = false
    ) -> UsageRecord {
        UsageRecord(
            id: id, timestamp: when, model: model,
            projectPath: project, sessionID: session, isSidechain: sidechain,
            inputTokens: input, cacheWrite5mTokens: cacheWrite5m,
            cacheWrite1hTokens: cacheWrite1h, cacheReadTokens: cacheRead,
            outputTokens: output, thinkingTokens: thinking
        )
    }

    private static func logLine(
        id: String,
        model: String = "claude-sonnet-5",
        input: Int = 10,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        output: Int,
        cwd: String? = "/Users/x/Documents/demo",
        timestamp: String = "2026-09-01T12:00:00.000Z",
        apiError: Bool = false,
        oneHourTTL: Bool = false
    ) -> String {
        var entry: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "isSidechain": false,
            "uuid": UUID().uuidString,
            "message": [
                "id": id,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": cacheWrite,
                    "cache_read_input_tokens": cacheRead,
                    "output_tokens": output,
                    "output_tokens_details": ["thinking_tokens": 0],
                    "cache_creation": [
                        "ephemeral_5m_input_tokens": oneHourTTL ? 0 : cacheWrite,
                        "ephemeral_1h_input_tokens": oneHourTTL ? cacheWrite : 0,
                    ],
                ],
            ],
        ]
        if let cwd { entry["cwd"] = cwd }
        if apiError { entry["isApiErrorMessage"] = true }
        let data = try! JSONSerialization.data(withJSONObject: entry)
        return String(decoding: data, as: UTF8.self)
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokencounter-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func appendText(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}
