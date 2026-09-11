import SwiftUI

/// Spend per session, which is what "why was yesterday expensive?" actually
/// resolves to. Model and project rollups can't answer it: one runaway
/// conversation looks identical to steady use spread across a week.
struct SessionBreakdown: View {
    let aggregates: Aggregates

    /// Sessions run to the hundreds, and the tail is all noise.
    private static let collapsedLimit = 8

    @State private var showingAll = false

    private var rows: [SessionStat] {
        showingAll ? aggregates.sessions : Array(aggregates.sessions.prefix(Self.collapsedLimit))
    }

    private var maxCost: Double {
        max(aggregates.sessions.first?.cost ?? 0, 0.000001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Most expensive sessions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if aggregates.sessions.count > Self.collapsedLimit {
                    Button(showingAll
                           ? "Show top \(Self.collapsedLimit)"
                           : "Show all \(Fmt.integer(aggregates.sessions.count))") {
                        showingAll.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if aggregates.sessions.isEmpty {
                Text("No usage in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("SESSION")
                            .gridColumnAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("WHEN")
                        Text("TURNS")
                        Text("TOKENS")
                        Text("COST")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(rows) { session in
                        GridRow {
                            HStack(spacing: 6) {
                                Text(session.projectLabel)
                                    .font(.system(size: 11, weight: .medium))
                                Text(session.shortID)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                            .help("Session \(session.id)\n\(session.projectPath)")

                            Text(Fmt.axisLabel(session.start, unit: .day))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)

                            Text(Fmt.integer(session.totals.responses))
                                .font(.system(size: 11))
                                .monospacedDigit()

                            Text(Fmt.tokens(session.totals.total))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()

                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Fmt.money(session.cost))
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.accent)
                                ShareBar(fraction: session.cost / maxCost)
                                    .frame(width: 64)
                            }
                            .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .card()
    }
}

/// Progress against a spending limit, shown only once a limit is set.
struct BudgetBar: View {
    let budgets: BudgetStore
    var compact = false

    var body: some View {
        if let (period, fraction) = budgets.mostPressing, let limit = budgets.limit(for: period) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(compact
                         ? "\(period.title.lowercased()) budget"
                         : "\(period.title) budget: \(Fmt.money(budgets.spend(for: period))) of \(Fmt.money(limit))")
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(Fmt.percent(fraction))
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(fraction >= 1 ? .orange : .secondary)
                }
                ShareBar(fraction: fraction, color: fraction >= 1 ? .orange : Palette.accent)
            }
            .help("\(Fmt.money(budgets.spend(for: period))) of \(Fmt.money(limit)) — \(Copy.listPriceShort)")
        }
    }
}
