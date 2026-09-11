import SwiftUI

/// Sortable per-model breakdown.
///
/// This is also the chart's table view: three light-mode series colors sit below
/// 3:1 contrast on the surface, so identity has to be readable as text somewhere.
struct ModelTable: View {
    let aggregates: Aggregates
    let colorMap: ModelColorMap

    @State private var sort: Column = .cost
    @State private var ascending = false

    enum Column: String, CaseIterable, Identifiable {
        case model, responses, input, cacheWrite, cacheRead, output, thinking, total, cost

        var id: String { rawValue }

        var title: String {
            switch self {
            case .model:      return "Model"
            case .responses:  return "Turns"
            case .input:      return "Input"
            case .cacheWrite: return "Cache write"
            case .cacheRead:  return "Cache read"
            case .output:     return "Output"
            case .thinking:   return "Thinking"
            case .total:      return "Total tokens"
            case .cost:       return "Cost"
            }
        }

        var isNumeric: Bool { self != .model }

        /// Sorting a numeric column starts descending; a name column ascending.
        var defaultAscending: Bool { self == .model }
    }

    private var rows: [ModelStat] {
        let sorted = aggregates.models.sorted { a, b in
            switch sort {
            case .model:      return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            case .responses:  return a.responses < b.responses
            case .input:      return a.input < b.input
            case .cacheWrite: return a.cacheWrite < b.cacheWrite
            case .cacheRead:  return a.cacheRead < b.cacheRead
            case .output:     return a.output < b.output
            case .thinking:   return a.thinking < b.thinking
            case .total:      return a.total < b.total
            case .cost:       return a.cost < b.cost
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private var maxCost: Double {
        max(aggregates.models.map(\.cost).max() ?? 0, 0.000001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage by model")
                .font(.system(size: 13, weight: .semibold))

            if aggregates.models.isEmpty {
                Text("No usage in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
                    headerRow
                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(rows) { row in
                        dataRow(row)
                        Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                    }

                    totalRow
                }
                .font(.system(size: 12))
            }
        }
        .card(padding: 14)
    }

    private var headerRow: some View {
        GridRow {
            ForEach(Column.allCases) { column in
                Button {
                    if sort == column {
                        ascending.toggle()
                    } else {
                        sort = column
                        ascending = column.defaultAscending
                    }
                } label: {
                    HStack(spacing: 3) {
                        if column.isNumeric { Spacer(minLength: 0) }
                        Text(column.title.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.5)
                        if sort == column {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        if !column.isNumeric { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(sort == column ? Color.primary : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .gridColumnAlignment(column.isNumeric ? .trailing : .leading)
            }
        }
        .padding(.bottom, 6)
    }

    private func dataRow(_ row: ModelStat) -> some View {
        GridRow {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.series(colorMap.slot(for: colorMap.seriesKey(for: row.id))))
                    .frame(width: 8, height: 8)
                Text(row.displayName)
                    .fontWeight(.medium)
                if !row.hasKnownRate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("No pricing entry for \(row.id) — its cost is counted as $0, so the total is understated. Add a rate in Settings › Pricing.")
                }
                Spacer(minLength: 0)
            }
            .help(row.id)

            numeric(Fmt.integer(row.responses))
            numeric(Fmt.tokens(row.input))
            numeric(Fmt.tokens(row.cacheWrite))
            numeric(Fmt.tokens(row.cacheRead))
            numeric(Fmt.tokens(row.output))
            numeric(Fmt.tokens(row.thinking))
            numeric(Fmt.tokens(row.total))

            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.money(row.cost))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Palette.accent)
                ShareBar(fraction: row.cost / maxCost)
            }
        }
        .padding(.vertical, 6)
    }

    private var totalRow: some View {
        GridRow {
            Text("Total")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            numeric(Fmt.integer(aggregates.totals.responses), bold: true)
            numeric(Fmt.tokens(aggregates.totals.input), bold: true)
            numeric(Fmt.tokens(aggregates.totals.cacheWrite), bold: true)
            numeric(Fmt.tokens(aggregates.totals.cacheRead), bold: true)
            numeric(Fmt.tokens(aggregates.totals.output), bold: true)
            numeric(Fmt.tokens(aggregates.totals.thinking), bold: true)
            numeric(Fmt.tokens(aggregates.totals.total), bold: true)
            Text(Fmt.money(aggregates.totals.cost))
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(Palette.accent)
        }
        .padding(.top, 8)
    }

    private func numeric(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(bold ? Color.primary : Color.primary.opacity(0.82))
    }
}

/// A thin proportion bar, anchored to the row's trailing edge.
///
/// The track is what makes it read as a share rather than an underline: without
/// it, the largest row's full-width fill looks like text decoration.
struct ShareBar: View {
    let fraction: Double
    var color: Color = Palette.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 3)
                Capsule()
                    .fill(color.opacity(0.75))
                    .frame(width: max(2, geo.size.width * clamped), height: 3)
            }
            .frame(width: geo.size.width, height: 3)
        }
        .frame(height: 3)
    }

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
