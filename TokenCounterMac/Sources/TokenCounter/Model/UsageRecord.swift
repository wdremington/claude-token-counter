import Foundation

/// One assistant API response, as recorded in a Claude Code session log.
///
/// Deliberately carries **no cost and no project label**. Both are facts about a
/// set and a price list rather than facts about the response, and baking them in
/// here would mean every rate change invalidated the scanner's incremental file
/// cache and forced a full re-parse. Cost is computed during aggregation; labels
/// are assigned once the set of projects in range is known.
struct UsageRecord: Identifiable, Equatable {
    /// The API message id. Unique per response, and the key used to collapse the
    /// duplicate snapshots Claude Code writes while a response streams.
    let id: String

    let timestamp: Date

    /// Exactly as logged, including any `[1m]` context-tier suffix. This is the
    /// rollup and display key: a 1M-context turn can price differently, so it
    /// belongs in its own row.
    let model: String
    /// `model` with the tier suffix removed - the key the rate table is keyed by.
    /// Split once here so no downstream call site parses the string again.
    let canonicalModel: String
    let contextTier: ContextTier

    /// The full working directory. Identity, not a label: two projects can share
    /// a last path segment, so anything shorter collides.
    let projectPath: String
    /// The session log's filename stem, so spend can be traced to one conversation.
    let sessionID: String

    let isSidechain: Bool

    let inputTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int

    /// Thinking tokens are a subset of `outputTokens`, already billed as output.
    /// Tracked for reporting only - never added into a token total.
    let thinkingTokens: Int

    var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }

    /// Every token the request touched.
    ///
    /// Note this weights a cache-read token the same as an output token, which
    /// they are not in dollars - it is a volume measure, not an invoice. Use
    /// `Pricer.cost(of:)` for anything money-shaped.
    var totalTokens: Int {
        inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens
    }

    init(
        id: String,
        timestamp: Date,
        model: String,
        projectPath: String,
        sessionID: String = "",
        isSidechain: Bool = false,
        inputTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        thinkingTokens: Int
    ) {
        let (canonical, tier) = ContextTier.split(model)
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.canonicalModel = canonical
        self.contextTier = tier
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.isSidechain = isSidechain
        self.inputTokens = inputTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
    }

    /// Return a copy pointed at a different project, used when an entry carried
    /// no `cwd` and the directory's modal path is resolved after parsing.
    func withProjectPath(_ path: String) -> UsageRecord {
        UsageRecord(
            id: id, timestamp: timestamp, model: model, projectPath: path,
            sessionID: sessionID, isSidechain: isSidechain,
            inputTokens: inputTokens, cacheWrite5mTokens: cacheWrite5mTokens,
            cacheWrite1hTokens: cacheWrite1hTokens, cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens, thinkingTokens: thinkingTokens
        )
    }

    /// Which of two snapshots of the same message to keep.
    ///
    /// Claude Code appends a fresh log line as a response streams, so the same
    /// message id appears many times (up to 28 in practice) with identical input
    /// and cache counts but a growing `output_tokens`. The last snapshot is the
    /// complete one, so the highest output count wins.
    func supersedes(_ other: UsageRecord) -> Bool {
        if outputTokens != other.outputTokens { return outputTokens > other.outputTokens }
        if totalTokens != other.totalTokens { return totalTokens > other.totalTokens }
        return timestamp > other.timestamp
    }
}

// MARK: - Archive encoding

/// Short keys, and token counts only - never dollars. Storing the raw `model`
/// (suffix included) is what makes archived history re-priceable: the context
/// tier is recovered from it on decode rather than persisted separately, so the
/// two can never drift apart.
extension UsageRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id = "i"
        case timestamp = "t"
        case model = "m"
        case projectPath = "p"
        case sessionID = "s"
        case isSidechain = "sc"
        case inputTokens = "in"
        case cacheWrite5mTokens = "w5"
        case cacheWrite1hTokens = "w1"
        case cacheReadTokens = "cr"
        case outputTokens = "ou"
        case thinkingTokens = "th"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            timestamp: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .timestamp)),
            model: try c.decode(String.self, forKey: .model),
            projectPath: try c.decode(String.self, forKey: .projectPath),
            sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID) ?? "",
            isSidechain: try c.decodeIfPresent(Bool.self, forKey: .isSidechain) ?? false,
            inputTokens: try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            cacheWrite5mTokens: try c.decodeIfPresent(Int.self, forKey: .cacheWrite5mTokens) ?? 0,
            cacheWrite1hTokens: try c.decodeIfPresent(Int.self, forKey: .cacheWrite1hTokens) ?? 0,
            cacheReadTokens: try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0,
            outputTokens: try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            thinkingTokens: try c.decodeIfPresent(Int.self, forKey: .thinkingTokens) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try c.encode(model, forKey: .model)
        try c.encode(projectPath, forKey: .projectPath)
        if !sessionID.isEmpty { try c.encode(sessionID, forKey: .sessionID) }
        if isSidechain { try c.encode(true, forKey: .isSidechain) }
        if inputTokens != 0 { try c.encode(inputTokens, forKey: .inputTokens) }
        if cacheWrite5mTokens != 0 { try c.encode(cacheWrite5mTokens, forKey: .cacheWrite5mTokens) }
        if cacheWrite1hTokens != 0 { try c.encode(cacheWrite1hTokens, forKey: .cacheWrite1hTokens) }
        if cacheReadTokens != 0 { try c.encode(cacheReadTokens, forKey: .cacheReadTokens) }
        if outputTokens != 0 { try c.encode(outputTokens, forKey: .outputTokens) }
        if thinkingTokens != 0 { try c.encode(thinkingTokens, forKey: .thinkingTokens) }
    }
}

// MARK: - Project labels

/// Turns a set of project paths into the shortest labels that stay unique.
///
/// A label is a property of the *set*, not of a path, so this cannot live on
/// `UsageRecord` - `/alice/work/api` and `/bob/personal/api` are both "api"
/// until you know the other one exists.
enum ProjectLabeler {
    static let unknown = "unknown"

    /// Deepest suffix considered before falling back to the full path.
    private static let maxDepth = 6

    static func labels(for paths: [String]) -> [String: String] {
        var pending = Set(paths)
        var out: [String: String] = [:]

        for path in pending where segments(of: path).isEmpty {
            out[path] = unknown
            pending.remove(path)
        }

        var depth = 1
        while !pending.isEmpty && depth <= maxDepth {
            // A suffix earns a label only if exactly one path claims it.
            var claimants: [String: [String]] = [:]
            for path in pending {
                claimants[suffix(of: path, depth: depth), default: []].append(path)
            }
            for (label, owners) in claimants where owners.count == 1 {
                out[owners[0]] = label
                pending.remove(owners[0])
            }
            depth += 1
        }

        // Still colliding at max depth: only the full path distinguishes them.
        for path in pending { out[path] = path }
        return out
    }

    private static func segments(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func suffix(of path: String, depth: Int) -> String {
        let parts = segments(of: path)
        // A path shorter than `depth` has no deeper form; returning the whole
        // thing lets it settle rather than colliding with itself forever.
        return parts.suffix(depth).joined(separator: "/")
    }
}
