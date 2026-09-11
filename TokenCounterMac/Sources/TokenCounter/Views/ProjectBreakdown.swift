import SwiftUI

/// Per-project spend, expandable into a per-model breakdown.
struct ProjectBreakdown: View {
    let aggregates: Aggregates
    let colorMap: ModelColorMap

    @State private var expanded: Set<String> = []

    private var maxCost: Double {
        max(aggregates.projects.map(\.cost).max() ?? 0, 0.000001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("By project")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if aggregates.projects.count > 1 {
                    Button(expanded.isEmpty ? "Expand all" : "Collapse all") {
                        expanded = expanded.isEmpty ? Set(aggregates.projects.map(\.id)) : []
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if aggregates.projects.isEmpty {
                Text("No usage in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(aggregates.projects.enumerated()), id: \.element.id) { index, project in
                        projectRow(project)
                        if index < aggregates.projects.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .card(padding: 14)
    }

    private func projectRow(_ project: ProjectStat) -> some View {
        let isOpen = expanded.contains(project.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(project.id) } else { expanded.insert(project.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))

                    Text(project.label)
                        .font(.system(size: 12, weight: .medium))
                        .help(project.path)

                    Spacer(minLength: 12)

                    Text("\(Fmt.integer(project.totals.responses)) turns")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Text(Fmt.tokens(project.totals.total))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 66, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(Fmt.money(project.cost))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.accent)
                        ShareBar(fraction: project.cost / maxCost)
                            .frame(width: 70)
                    }
                    .frame(width: 70, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                modelRows(project)
                    .padding(.leading, 22)
                    .padding(.bottom, 8)
            }
        }
    }

    private func modelRows(_ project: ProjectStat) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Text("MODEL")
                    .gridColumnAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("TURNS")
                Text("TOKENS")
                Text("COST")
            }
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)

            ForEach(project.models) { model in
                GridRow {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.series(colorMap.slot(for: colorMap.seriesKey(for: model.id))))
                            .frame(width: 7, height: 7)
                        Text(model.displayName)
                            .help(model.id)
                        Spacer(minLength: 0)
                    }

                    Text(Fmt.integer(model.responses)).monospacedDigit()
                    Text(Fmt.tokens(model.total)).monospacedDigit()
                    Text(Fmt.money(model.cost))
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent)
                }
                .font(.system(size: 11))
            }
        }
    }
}
