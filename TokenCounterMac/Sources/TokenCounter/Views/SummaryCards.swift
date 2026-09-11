import SwiftUI

/// A single stat tile: label, hero number, one line of context.
struct StatTile: View {
    let label: String
    let value: String
    var detail: String?
    var emphasized = false
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasized ? Palette.accent : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(detail ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card(padding: 0)
        .help(help ?? "")
    }
}

struct SummaryCards: View {
    let aggregates: Aggregates
    let recordsInRange: Int

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 10)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            StatTile(
                label: "Cost",
                value: Fmt.money(aggregates.totals.cost),
                detail: Fmt.rangeLabel(aggregates.interval),
                emphasized: true,
                help: Copy.listPriceNote
            )
            StatTile(
                label: "Total tokens",
                value: Fmt.tokens(aggregates.totals.total),
                detail: "\(Fmt.tokens(aggregates.totals.output)) output",
                help: """
                      Every token touched, weighted equally. A cache-read token \
                      costs far less than an output token, so this is a volume \
                      measure rather than an invoice — see the cost column.
                      """
            )
            StatTile(
                label: "Responses",
                value: Fmt.integer(aggregates.totals.responses),
                detail: "\(Fmt.integer(aggregates.models.count)) model\(aggregates.models.count == 1 ? "" : "s")"
            )
            StatTile(
                label: "Cache reads",
                value: Fmt.percent(aggregates.totals.cacheHitRate),
                detail: "\(Fmt.tokens(aggregates.totals.cacheRead)) of input side"
            )
            StatTile(
                label: "Projects",
                value: Fmt.integer(aggregates.projects.count),
                detail: aggregates.projects.first.map { "top: \($0.label)" } ?? "no activity"
            )
            StatTile(
                label: "Thinking",
                value: Fmt.tokens(aggregates.totals.thinking),
                detail: aggregates.totals.output > 0
                    ? "\(Fmt.percent(Double(aggregates.totals.thinking) / Double(aggregates.totals.output))) of output"
                    : "—"
            )
        }
    }
}
