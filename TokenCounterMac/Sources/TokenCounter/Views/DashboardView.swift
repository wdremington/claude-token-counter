import AppKit
import Combine
import SwiftUI

struct DashboardView: View {
    @Bindable var store: UsageStore

    /// Rolling ranges ("Today", "Last hour") drift as the clock advances.
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            RangeBar(store: store)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            if !store.rootExists {
                missingLogs
            } else if !store.hasLoadedOnce {
                loading
            } else {
                content
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onReceive(clock, perform: { _ in store.refreshTimeDependentRanges() })
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = store.scanError {
                    notice(error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }

                if !store.aggregates.unpricedModels.isEmpty {
                    notice(
                        "No pricing for \(store.aggregates.unpricedModels.joined(separator: ", ")) — counted as $0, so the total is understated.",
                        systemImage: "questionmark.circle.fill",
                        tint: .orange
                    )
                }

                SummaryCards(aggregates: store.aggregates, recordsInRange: store.aggregates.recordCount)

                if store.budgets.isActive {
                    BudgetBar(budgets: store.budgets).card(padding: 12)
                }

                UsageChart(
                    aggregates: store.aggregates,
                    metric: store.metric,
                    colorMap: store.colorMap
                )

                ModelTable(aggregates: store.aggregates, colorMap: store.colorMap)

                ProjectBreakdown(aggregates: store.aggregates, colorMap: store.colorMap)

                SessionBreakdown(aggregates: store.aggregates)

                footer
            }
            .padding(18)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(Fmt.integer(store.records.count)) billable responses across \(store.fileCount) session logs")
            if store.duplicatesCollapsed > 0 {
                Text("·")
                Text("\(Fmt.integer(store.duplicatesCollapsed)) duplicate log lines collapsed")
                    .help("""
                          Claude Code appends a new log line as a response streams, so one \
                          response appears many times. Only the final snapshot of each \
                          message is counted — otherwise cost would be overstated roughly \
                          twofold.
                          """)
            }
            if store.archivedRecordCount > 0 {
                Text("·")
                Text("\(Fmt.integer(store.archivedRecordCount)) recovered from history")
                    .help("""
                          These responses are no longer in Claude Code's logs — it has \
                          pruned them — but TokenCounter kept its own copy. Manage it in \
                          Settings › History.
                          """)
            }
            Text("·")
            Text("API list prices")
                .help(Copy.listPriceNote)
            Spacer()
            Button("Copy CSV") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.exportCSV(), forType: .string)
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(0.30), lineWidth: 1)
            )
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading session logs…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingLogs: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No Claude Code logs found")
                .font(.headline)
            Text(store.root.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Rescan") { store.refresh() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
