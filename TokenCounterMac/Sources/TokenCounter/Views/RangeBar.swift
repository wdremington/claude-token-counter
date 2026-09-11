import SwiftUI

/// The filter row: range, granularity, metric, and scan controls.
struct RangeBar: View {
    @Bindable var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                rangeMenu
                granularityPicker
                metricPicker

                Spacer(minLength: 8)

                Toggle(isOn: $store.includeSidechains) {
                    Text("Subagents")
                }
                .toggleStyle(.checkbox)
                .help("Include subagent (sidechain) responses, which are billed like any other API call.")

                scanStatus
            }

            if store.preset == .custom {
                customRangeControls
            }

            if store.granularityWasCoarsened {
                Label(
                    "Showing \(store.resolvedUnit.title.lowercased()) buckets — the pinned granularity would need too many bars for this range.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var rangeMenu: some View {
        Menu {
            Section("Rolling") {
                ForEach(RangePreset.rollingGroup) { preset in
                    Button(preset.title) { store.preset = preset }
                }
            }
            Section("Calendar") {
                ForEach(RangePreset.calendarGroup) { preset in
                    Button(preset.title) { store.preset = preset }
                }
            }
            Section {
                Button(RangePreset.allTime.title) { store.preset = .allTime }
                Button(RangePreset.custom.title) {
                    // Start the custom range from whatever is on screen now.
                    store.seedCustomRangeFromCurrentSelection()
                    store.preset = .custom
                }
            }
        } label: {
            Label(store.preset.title, systemImage: "calendar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var granularityPicker: some View {
        Picker("Buckets", selection: $store.granularity) {
            ForEach(GranularityChoice.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("How the time axis is bucketed.")
    }

    private var metricPicker: some View {
        Picker("Metric", selection: $store.metric) {
            ForEach(ChartMetric.allCases) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// Date *and* time of day for both ends of the range.
    private var customRangeControls: some View {
        HStack(spacing: 12) {
            DatePicker(
                "From",
                selection: $store.customStart,
                in: ...store.customEnd,
                displayedComponents: [.date, .hourAndMinute]
            )
            .fixedSize()

            DatePicker(
                "To",
                selection: $store.customEnd,
                in: store.customStart...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .fixedSize()

            if let bounds = store.dataBounds {
                Button("Full extent") {
                    store.customStart = bounds.start
                    store.customEnd = bounds.end
                }
                .help("Snap to the first and last recorded response.")
            }

            Spacer()
        }
        .padding(.top, 2)
        .font(.callout)
    }

    private var scanStatus: some View {
        HStack(spacing: 8) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan now (⌘R). Logs are also watched for changes automatically.")
            .disabled(store.isScanning)
        }
    }

    private var statusText: String {
        if store.isScanning { return "Scanning \(store.fileCount) logs…" }
        guard let last = store.lastScan else { return "" }
        return "Updated \(Fmt.clockTime(last))"
    }
}
