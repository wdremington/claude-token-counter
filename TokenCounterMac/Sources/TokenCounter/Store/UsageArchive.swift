import Foundation
import Observation

/// Keeps usage history after Claude Code's own logs are gone.
///
/// Claude Code rotates and prunes `~/.claude/projects`, and a user who clears it
/// would otherwise lose every number this app has ever shown. Deduplicated
/// records are mirrored into one JSON file per **UTC** month and merged back in
/// at launch.
///
/// Two rules make the mirror safe to trust:
///
/// - **Tokens only, never dollars.** History has to re-price when rates change
///   or the user edits an override, which it cannot do if a dollar figure was
///   frozen into the file.
/// - **Merging uses the same `supersedes` rule as the scanner.** A rotated file
///   that gets re-read may yield only an early streaming snapshot of a message
///   the archive already holds complete, so "live always wins" would quietly
///   corrupt history.
@MainActor
@Observable
final class UsageArchive {

    struct MonthFile: Codable {
        var schema: Int = MonthFile.currentSchema
        var month: String
        var records: [UsageRecord]

        static let currentSchema = 1
    }

    // MARK: - State

    private(set) var byMonth: [String: [String: UsageRecord]] = [:]
    private(set) var quarantined: [String] = []
    private(set) var isReadOnly = false
    private(set) var lastError: String?

    /// Months whose in-memory contents have diverged from disk.
    private var dirty: Set<String> = []

    /// True while some month still needs writing. Per-month granularity is the
    /// point: a resumed old session dirties one old month, and a single archive
    /// file would mean rewriting every record on every burst of file events.
    var hasPendingWrites: Bool { !dirty.isEmpty }

    private let directory: URL

    /// A file descriptor, not UI state: exempt from observation, and reachable
    /// from the nonisolated `deinit` that has to close it.
    @ObservationIgnored
    nonisolated(unsafe) private var lockDescriptor: Int32 = -1

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            if isEnabled { load() } else { byMonth = [:]; dirty = [] }
        }
    }

    var recordCount: Int { byMonth.values.reduce(0) { $0 + $1.count } }

    var diskSize: Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(into: Int64(0)) { total, name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    private enum Key {
        static let enabled = "archive.enabled"
    }

    init(directory: URL = AppPaths.archive, enabled: Bool? = nil, autoload: Bool = true) {
        self.directory = directory
        self.isEnabled = enabled ?? (UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true)
        if autoload && isEnabled { load() }
    }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    // MARK: - Month keys

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    /// UTC rather than local, so a record does not change months when the user
    /// travels - which would leave it written into two files.
    static func monthKey(for date: Date) -> String {
        let parts = utc.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    // MARK: - Loading

    func load() {
        byMonth = [:]
        dirty = []
        quarantined = []
        lastError = nil

        guard AppPaths.ensure(directory) else {
            lastError = "Could not create \(directory.path)"
            isReadOnly = true
            return
        }
        acquireLock()

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            let month = String(name.dropLast(".json".count))
            // Each month is decoded independently: one bad file must not cost
            // the user every other month of history.
            guard let loaded = Self.load(file: file) else {
                quarantine(file)
                continue
            }
            byMonth[month] = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: {
                $1.supersedes($0) ? $1 : $0
            })
        }
    }

    static func load(file: URL) -> [UsageRecord]? {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(MonthFile.self, from: data),
              // A newer build may have written fields this one would silently drop.
              decoded.schema <= MonthFile.currentSchema
        else { return nil }
        return decoded.records
    }

    /// Never deleted - a corrupt month is still the only copy the user has.
    private func quarantine(_ file: URL) {
        let target = file.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: file, to: target)
        quarantined.append(target.lastPathComponent)
    }

    // MARK: - Locking

    /// Two running copies would otherwise take turns overwriting each other's
    /// months. The loser keeps reading history but stops writing it.
    private func acquireLock() {
        guard lockDescriptor < 0 else { return }
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { isReadOnly = true; return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockDescriptor = fd
            isReadOnly = false
        } else {
            close(fd)
            isReadOnly = true
        }
    }

    // MARK: - Merging

    /// Fold a live scan into the archive and return the union, newest snapshot
    /// of each message winning.
    func integrate(live: [UsageRecord]) -> [UsageRecord] {
        guard isEnabled else { return live }

        for record in live {
            let month = Self.monthKey(for: record.timestamp)
            if let existing = byMonth[month]?[record.id] {
                guard record.supersedes(existing) else { continue }
            }
            byMonth[month, default: [:]][record.id] = record
            dirty.insert(month)
        }

        return byMonth.values
            .flatMap(\.values)
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Writing

    /// Rewrites only the months that changed. Whole-file and atomic: a
    /// half-written JSON array is unrecoverable, which is why this does not
    /// append the way the input logs do.
    func flush() {
        guard isEnabled, !isReadOnly, !dirty.isEmpty else { return }
        guard AppPaths.ensure(directory) else { return }

        let encoder = JSONEncoder()
        for month in dirty {
            guard let records = byMonth[month], !records.isEmpty else { continue }
            let file = MonthFile(month: month, records: records.values.sorted { $0.timestamp < $1.timestamp })
            guard let data = try? encoder.encode(file) else { continue }
            do {
                try data.write(to: directory.appendingPathComponent("\(month).json"), options: .atomic)
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        dirty = []
    }

    func clear() {
        byMonth = [:]
        dirty = []
        quarantined = []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
