import Foundation

/// `TokenCounter --audit` prints the parsed totals and exits.
///
/// Exists so the scanner's arithmetic can be checked without the UI, and
/// diffed against an independent implementation. Prices with the **bundled**
/// table only - no network, no user overrides - so two runs on the same logs
/// are comparable.
/// `TokenCounter --dump-catalog` prints the bundled rate table as the JSON the
/// remote refresh expects.
///
/// Exists so the published catalog is generated from the compiled table rather
/// than maintained twice and allowed to drift:
///
///     ./build/TokenCounter.app/Contents/MacOS/TokenCounter --dump-catalog > pricing/catalog.json
enum DumpCatalogMode {
    static let flag = "--dump-catalog"

    static func runAndExit() -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Pricing.bundled) else {
            FileHandle.standardError.write(Data("could not encode the bundled catalog\n".utf8))
            exit(1)
        }
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
}

enum AuditMode {
    static let flag = "--audit"

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func runAndExit() -> Never {
        let root = UsageStore.resolvedRoot(override: UserDefaults.standard.string(forKey: "logs.rootOverride"))
        let box = Box(LogScanner.Result())
        let done = DispatchSemaphore(value: 0)

        Task.detached {
            box.value = await LogScanner.scan(root: root, previous: [:])
            done.signal()
        }
        done.wait()

        let result = box.value
        guard result.rootExists else {
            print("no logs at \(root.path)")
            exit(1)
        }

        let pricer = Pricer(layers: [Pricing.bundled])

        var totals = TokenTotals()
        var byModel: [String: TokenTotals] = [:]
        var unpriced = Set<String>()
        for record in result.records {
            let cost = pricer.cost(of: record)
            if !cost.hasKnownRate { unpriced.insert(record.model) }
            totals.add(record, cost: cost)
            byModel[record.model, default: TokenTotals()].add(record, cost: cost)
        }

        print("root:                 \(root.path)")
        print("session logs:         \(result.fileCount)")
        print("billable responses:   \(result.records.count)")
        print("duplicates collapsed: \(result.duplicatesCollapsed)")
        if let bounds = result.bounds {
            print("range:                \(bounds.start) .. \(bounds.end)")
        }
        if !unpriced.isEmpty {
            print("unpriced models:      \(unpriced.sorted().joined(separator: ", "))")
        }
        print("")
        print("model".padding(toLength: 34, withPad: " ", startingAt: 0)
              + "turns".leftPad(8) + "tokens".leftPad(15)
              + "output".leftPad(15) + "cost".leftPad(13))

        for (model, t) in byModel.sorted(by: { $0.value.cost > $1.value.cost }) {
            print(model.padding(toLength: 34, withPad: " ", startingAt: 0)
                  + String(t.responses).leftPad(8)
                  + String(t.total).leftPad(15)
                  + String(t.output).leftPad(15)
                  + String(format: "%.4f", t.cost).leftPad(13))
        }

        print("")
        print("TOTAL tokens:         \(totals.total)")
        print(String(format: "  input:              $%.4f", totals.costs.input))
        print(String(format: "  cache write:        $%.4f", totals.costs.cacheWrite))
        print(String(format: "  cache read:         $%.4f", totals.costs.cacheRead))
        print(String(format: "  output:             $%.4f", totals.costs.output))
        if totals.costs.longContextSurcharge > 0 {
            print(String(format: "  long-context 1M:    $%.4f", totals.costs.longContextSurcharge))
        }
        print(String(format: "TOTAL cost:           $%.4f", totals.cost))
        print("")
        print("Anthropic API list prices. Not a bill; does not reflect Max/Pro")
        print("subscriptions, Bedrock/Vertex rates, or batch discounts.")
        exit(0)
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
