import AppKit
import SwiftUI

/// The status-bar label: running cost for the menu bar's own range.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
            Text(Fmt.moneyCompact(store.menuBarTotals.cost))
                .monospacedDigit()
        }
    }
}

/// The popover behind the status-bar item.
struct MenuBarContentView: View {
    @Bindable var store: UsageStore

    @Environment(\.openWindow) private var openWindow

    private var topProjects: [ProjectStat] {
        Array(store.aggregates.projects.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.menuBarModels.isEmpty {
                Text("No usage in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                modelList
            }

            Divider()
            actions
        }
        .frame(width: 288)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.money(store.menuBarTotals.cost))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.accent)
                    Text("\(Fmt.integer(store.menuBarTotals.responses)) turns · \(Fmt.tokens(store.menuBarTotals.total)) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            // Defaults to following the dashboard, so the number in the status
            // bar and the number in the window can't quietly disagree.
            Picker("", selection: $store.menuBarPreset) {
                Text("Same as dashboard — \(store.preset.title)").tag(RangePreset?.none)
                Divider()
                ForEach(RangePreset.rollingGroup + RangePreset.calendarGroup + [.allTime]) { preset in
                    Text(preset.title).tag(RangePreset?.some(preset))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)

            if store.budgets.isActive {
                BudgetBar(budgets: store.budgets, compact: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(store.menuBarModels) { model in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.series(store.colorMap.slot(for: store.colorMap.seriesKey(for: model.id))))
                        .frame(width: 8, height: 8)
                    Text(model.displayName)
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                    Text(Fmt.tokens(model.total))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(Fmt.money(model.cost))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 6)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            menuButton("Open dashboard", key: "Return") {
                openWindow(id: DashboardScene.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("Rescan logs", key: "⌘R") {
                store.refresh()
            }
            SettingsLink {
                menuRow("Settings…", key: "⌘,")
            }
            .buttonStyle(.plain)
            Divider().padding(.vertical, 4)
            menuButton("Quit TokenCounter", key: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 6)
    }

    private func menuButton(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuRow(title, key: key) }
            .buttonStyle(.plain)
    }

    /// Shared so `SettingsLink`, which supplies its own button, still looks like
    /// the rows around it.
    private func menuRow(_ title: String, key: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
