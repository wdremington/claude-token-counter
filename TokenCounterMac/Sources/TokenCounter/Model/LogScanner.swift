import Foundation

/// Reads Claude Code session logs (`~/.claude/projects/**/*.jsonl`).
///
/// Rescans are incremental: a file that has not changed is reused, and a file
/// that only grew is read from the byte offset where the last pass stopped.
///
/// Nothing here knows about prices. Cost is computed during aggregation, so a
/// rate change costs a recompute rather than a full re-parse of every log.
enum LogScanner {

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// What a previous pass learned about one log file.
    struct FileState {
        var size: UInt64 = 0
        var modified: Date = .distantPast
        /// Byte offset just past the last complete line consumed.
        var offset: UInt64 = 0
        /// Best-known snapshot per API message id found in this file.
        var records: [String: UsageRecord] = [:]
        /// Every `cwd` seen in this file, with counts, so the directory's modal
        /// path can fill in entries that carry none.
        var cwdCounts: [String: Int] = [:]
        /// Every usable assistant line seen, before collapsing snapshots.
        var rawAssistantLines = 0
    }

    struct Result {
        var states: [URL: FileState] = [:]
        /// Deduplicated and sorted by time.
        var records: [UsageRecord] = []
        var bounds: DateInterval?
        var fileCount = 0
        /// Log lines that were superseded by a later snapshot of the same message.
        var duplicatesCollapsed = 0
        var rootExists = true
        var error: String?
    }

    // MARK: - Scanning

    static func scan(root: URL, previous: [URL: FileState]) async -> Result {
        var result = Result()

        guard FileManager.default.fileExists(atPath: root.path) else {
            result.rootExists = false
            return result
        }

        let files: [URL]
        do {
            files = try logFiles(under: root)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.fileCount = files.count

        // Decide per file whether to reuse, extend, or reread.
        enum Work { case reuse(FileState), parse(from: UInt64, carrying: FileState?) }
        var plan: [(url: URL, work: Work)] = []

        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast

            if let old = previous[url], old.size == size, old.modified == modified {
                plan.append((url, .reuse(old)))
            } else if let old = previous[url], size >= old.size, old.offset <= size {
                // Appended to: pick up where the last pass stopped.
                plan.append((url, .parse(from: old.offset, carrying: old)))
            } else {
                // New, truncated, or rewritten: read the whole thing.
                plan.append((url, .parse(from: 0, carrying: nil)))
            }
        }

        // Parse the files that need work off the main thread, in parallel.
        var parsed: [URL: FileState] = [:]
        await withTaskGroup(of: (URL, FileState)?.self) { group in
            for item in plan {
                guard case let .parse(offset, carried) = item.work else { continue }
                group.addTask {
                    guard let state = try? parseFile(at: item.url, from: offset, carrying: carried) else {
                        return nil
                    }
                    return (item.url, state)
                }
            }
            for await entry in group {
                if let entry { parsed[entry.0] = entry.1 }
            }
        }

        for item in plan {
            switch item.work {
            case .reuse(let state):
                result.states[item.url] = state
            case .parse:
                if let state = parsed[item.url] { result.states[item.url] = state }
            }
        }

        // Resolve entries that carried no `cwd`. This has to happen here rather
        // than in `parseFile`: a session file may have no `cwd` anywhere in it
        // while a sibling in the same directory does, and the task group parses
        // each file in isolation.
        let fallbacks = projectFallbacks(states: result.states)

        // Merge across files. The same message can appear in more than one file
        // (a resumed session replays history), so dedup has to be global.
        var merged: [String: UsageRecord] = [:]
        var rawLines = 0
        for (url, state) in result.states {
            let fallback = fallbacks[url.deletingLastPathComponent()] ?? ""
            rawLines += state.rawAssistantLines
            for (id, raw) in state.records {
                let record = raw.projectPath.isEmpty ? raw.withProjectPath(fallback) : raw
                if let existing = merged[id] {
                    if record.supersedes(existing) { merged[id] = record }
                } else {
                    merged[id] = record
                }
            }
        }

        result.records = merged.values.sorted { $0.timestamp < $1.timestamp }
        result.duplicatesCollapsed = max(0, rawLines - result.records.count)
        if let first = result.records.first?.timestamp, let last = result.records.last?.timestamp {
            result.bounds = DateInterval(start: first, end: max(last, first))
        }
        return result
    }

    /// The project path to use for `cwd`-less entries, per log directory.
    ///
    /// Claude Code names each project directory after the working directory with
    /// separators flattened to dashes, which is not reversible - a project whose
    /// own name contains a hyphen would come back as a fabricated path. So the
    /// real `cwd` observed in the same directory is used instead, taking the
    /// most common one. Only when a directory has no `cwd` anywhere is the
    /// flattened name used, and then verbatim rather than un-flattened.
    private static func projectFallbacks(states: [URL: FileState]) -> [URL: String] {
        var countsByDirectory: [URL: [String: Int]] = [:]
        for (url, state) in states {
            let directory = url.deletingLastPathComponent()
            for (path, count) in state.cwdCounts {
                countsByDirectory[directory, default: [:]][path, default: 0] += count
            }
        }

        var out: [URL: String] = [:]
        for (directory, counts) in countsByDirectory {
            // Ties broken lexicographically so the result is deterministic.
            out[directory] = counts.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }?.key
        }
        for (url, _) in states {
            let directory = url.deletingLastPathComponent()
            if out[directory] == nil { out[directory] = directory.lastPathComponent }
        }
        return out
    }

    private static func logFiles(under root: URL) throws -> [URL] {
        var out: [URL] = []
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return out }

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile { out.append(url) }
        }
        return out
    }

    // MARK: - Parsing

    /// Read from `offset` to EOF and fold the new lines into `carrying`.
    private static func parseFile(at url: URL, from offset: UInt64, carrying: FileState?) throws -> FileState {
        var state = carrying ?? FileState()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        state.size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        state.modified = (attrs[.modificationDate] as? Date) ?? .distantPast

        if carrying == nil {
            state.records = [:]
            state.cwdCounts = [:]
            state.rawAssistantLines = 0
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if offset > 0 { try handle.seek(toOffset: offset) }
        let data = try handle.readToEnd() ?? Data()

        // Only consume through the last newline; a trailing partial line will be
        // re-read next pass, once it is complete.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            state.offset = offset
            return state
        }
        let consumable = data[data.startIndex...lastNewline]
        state.offset = offset + UInt64(consumable.count)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        let sessionID = url.deletingPathExtension().lastPathComponent

        // A line we care about always contains the bytes `assistant`, so this
        // pre-filter skips user turns and tool results without parsing them.
        let marker = Array("assistant".utf8)

        for line in consumable.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty, contains(line, marker) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            guard let record = record(
                from: object,
                sessionID: sessionID,
                formatter: formatter,
                plainFormatter: plainFormatter
            ) else { continue }

            state.rawAssistantLines += 1
            if !record.projectPath.isEmpty {
                state.cwdCounts[record.projectPath, default: 0] += 1
            }
            if let existing = state.records[record.id] {
                if record.supersedes(existing) { state.records[record.id] = record }
            } else {
                state.records[record.id] = record
            }
        }

        return state
    }

    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { raw -> Bool in
            guard raw.count >= needle.count else { return false }
            let limit = raw.count - needle.count
            var i = 0
            while i <= limit {
                if raw[i] == needle[0] {
                    var j = 1
                    while j < needle.count, raw[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    private static func record(
        from entry: [String: Any],
        sessionID: String,
        formatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter
    ) -> UsageRecord? {
        guard entry["type"] as? String == "assistant" else { return nil }
        if entry["isApiErrorMessage"] as? Bool == true { return nil }

        guard let message = entry["message"] as? [String: Any],
              let model = message["model"] as? String,
              !model.isEmpty,
              model != "<synthetic>",
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = int(usage["input_tokens"])
        let cacheReads = int(usage["cache_read_input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheWriteFlat = int(usage["cache_creation_input_tokens"])

        // Cache writes are priced by TTL: 5-minute at 1.25x, 1-hour at 2x.
        var write5m = 0
        var write1h = 0
        if let split = usage["cache_creation"] as? [String: Any] {
            write5m = int(split["ephemeral_5m_input_tokens"])
            write1h = int(split["ephemeral_1h_input_tokens"])
        }
        if write5m + write1h == 0 {
            // No split recorded: charge the flat total at the 5-minute rate.
            write5m = cacheWriteFlat
        }

        guard input + write5m + write1h + cacheReads + output > 0 else { return nil }

        let thinking = int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])

        let stamp = entry["timestamp"] as? String ?? ""
        guard let timestamp = formatter.date(from: stamp) ?? plainFormatter.date(from: stamp) else { return nil }

        // Prefer the API message id: it is what makes streaming snapshots of one
        // response collapse into a single billable event.
        let id = (message["id"] as? String)
            ?? (entry["uuid"] as? String)
            ?? "\(stamp)|\(model)|\(input)|\(output)"

        // Left empty when absent; the caller fills it from the directory's modal
        // path once every file has been parsed.
        var path = (entry["cwd"] as? String) ?? ""
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        return UsageRecord(
            id: id,
            timestamp: timestamp,
            model: model,
            projectPath: path,
            sessionID: sessionID,
            isSidechain: entry["isSidechain"] as? Bool ?? false,
            inputTokens: input,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            cacheReadTokens: cacheReads,
            outputTokens: output,
            thinkingTokens: thinking
        )
    }

    private static func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        return 0
    }
}
