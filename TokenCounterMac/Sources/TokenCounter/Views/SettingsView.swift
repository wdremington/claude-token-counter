import AppKit
import SwiftUI

enum SettingsScene {
    static let windowID = "settings"
}

struct SettingsView: View {
    @Bindable var store: UsageStore

    var body: some View {
        TabView {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            PricingSettings(store: store, pricing: store.pricing)
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
            BudgetSettings(budgets: store.budgets)
                .tabItem { Label("Budgets", systemImage: "gauge.with.needle") }
            HistorySettings(store: store, archive: store.archive)
                .tabItem { Label("History", systemImage: "archivebox") }
        }
        .frame(width: 580, height: 460)
    }
}

private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var store: UsageStore
    @State private var pathText = ""

    var body: some View {
        Pane {
            SettingsSection(
                title: "Claude Code logs",
                footnote: """
                    Defaults to ~/.claude/projects. If you set CLAUDE_CONFIG_DIR in your \
                    shell, an app launched from Finder never sees it — point this at the \
                    projects folder directly instead.
                    """
            ) {
                HStack(spacing: 8) {
                    TextField("~/.claude/projects", text: $pathText)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { store.logRootOverride = pathText }
                    Button("Choose…", action: choose)
                    Button("Reset") {
                        pathText = ""
                        store.logRootOverride = nil
                    }
                    .disabled(store.logRootOverride == nil)
                }

                HStack(spacing: 6) {
                    Image(systemName: store.rootExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.rootExists ? .green : .orange)
                    Text(store.rootExists
                         ? "Reading \(Fmt.integer(store.fileCount)) session logs from \(store.root.path)"
                         : "Nothing found at \(store.root.path)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            SettingsSection(
                title: "Menu bar",
                footnote: """
                    "Same as dashboard" keeps the status bar number and the window \
                    showing the same span. Pick a fixed range only if you deliberately \
                    want them to differ.
                    """
            ) {
                Picker("Range", selection: $store.menuBarPreset) {
                    Text("Same as dashboard").tag(RangePreset?.none)
                    Divider()
                    ForEach(RangePreset.rollingGroup + RangePreset.calendarGroup + [.allTime]) { preset in
                        Text(preset.title).tag(RangePreset?.some(preset))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .onAppear { pathText = store.logRootOverride ?? "" }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.root
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathText = url.path
        store.logRootOverride = url.path
    }
}

// MARK: - Pricing

private struct PricingSettings: View {
    @Bindable var store: UsageStore
    @Bindable var pricing: PricingStore

    @State private var selectedModel = ""
    @State private var inputText = ""
    @State private var outputText = ""

    /// Every model the user actually has usage for, plus anything they have
    /// already overridden, so a model can be corrected before it next appears.
    private var knownModels: [String] {
        var ids = Set(store.records.map(\.canonicalModel))
        ids.formUnion(pricing.overrides.keys)
        return ids.sorted()
    }

    private var parsedRate: ModelRate? {
        guard let input = Double(inputText), let output = Double(outputText),
              input > 0, output > 0, input.isFinite, output.isFinite
        else { return nil }
        // Keep whatever cache-read override and long-context rule the table
        // already had; the user is correcting a price, not redesigning the model.
        let existing = pricing.pricer.rate(for: selectedModel)
        return ModelRate(input: input, output: output,
                         cacheReadPerMTok: existing?.cacheReadPerMTok,
                         longContext: existing?.longContext)
    }

    var body: some View {
        Pane {
            SettingsSection(title: "What these prices are", footnote: Copy.listPriceNote) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                    Text("Rates as of \(pricing.catalogDate ?? "—")")
                        .font(.system(size: 11))
                }
            }

            SettingsSection(
                title: "Automatic updates",
                footnote: pricing.isNetworkConfigured
                    ? """
                      One anonymous request for a static rate file. No account, no \
                      credentials, and no usage data ever leaves this machine. If it \
                      fails, the last good table is kept.
                      """
                    : """
                      No update URL is compiled into this build, so rates come from the \
                      bundled table and your own overrides. Everything works offline.
                      """
            ) {
                Toggle("Check for updated rates on launch", isOn: $pricing.autoRefresh)
                    .toggleStyle(.checkbox)
                    .disabled(!pricing.isNetworkConfigured)

                HStack(spacing: 8) {
                    Button("Check now") { Task { await pricing.refresh(force: true) } }
                        .disabled(!pricing.isNetworkConfigured || pricing.isRefreshing)
                    if pricing.isRefreshing { ProgressView().controlSize(.small) }
                    if let last = pricing.lastRefresh {
                        Text("Updated \(Fmt.relative(last))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if pricing.remote != nil {
                        Button("Forget downloaded rates") { pricing.clearRemoteCatalog() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }

                if let error = pricing.lastRefreshError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(
                title: "Your own rates",
                footnote: """
                    Overrides win over everything else and are matched on the exact \
                    model id. Use this for a model released after this build, or when \
                    your organisation is billed at a negotiated rate.
                    """
            ) {
                HStack(spacing: 8) {
                    Picker("Model", selection: $selectedModel) {
                        Text("Choose…").tag("")
                        ForEach(knownModels, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 260)
                }

                HStack(spacing: 8) {
                    Text("Input $/M").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0", text: $inputText).frame(width: 70).multilineTextAlignment(.trailing)
                    Text("Output $/M").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0", text: $outputText).frame(width: 70).multilineTextAlignment(.trailing)

                    Button("Save override") {
                        guard let rate = parsedRate else { return }
                        pricing.setOverride(rate, for: selectedModel)
                    }
                    .disabled(selectedModel.isEmpty || parsedRate == nil)
                }
                .monospacedDigit()

                if !pricing.overrides.isEmpty {
                    Divider()
                    ForEach(pricing.overrides.keys.sorted(), id: \.self) { id in
                        overrideRow(id)
                    }
                }
            }
        }
        .onChange(of: selectedModel) { _, model in
            guard let rate = pricing.effectiveRate(for: model) else {
                inputText = ""; outputText = ""; return
            }
            inputText = String(format: "%g", rate.input)
            outputText = String(format: "%g", rate.output)
        }
    }

    private func overrideRow(_ id: String) -> some View {
        let override = pricing.overrides[id]
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { override?.enabled ?? false },
                set: { pricing.setOverrideEnabled($0, for: id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(id)
                .font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 8)
            Text("$\(String(format: "%g", override?.rate.input ?? 0)) / $\(String(format: "%g", override?.rate.output ?? 0))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                pricing.removeOverride(for: id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Budgets

private struct BudgetSettings: View {
    @Bindable var budgets: BudgetStore

    var body: some View {
        Pane {
            SettingsSection(
                title: "Limits",
                footnote: """
                    Measured against Anthropic API list prices over the calendar day \
                    and calendar month, independent of whatever range the dashboard is \
                    showing.
                    """
            ) {
                OptionalAmountField(label: "Daily", value: $budgets.dailyLimit)
                OptionalAmountField(label: "Monthly", value: $budgets.monthlyLimit)

                ForEach(BudgetStore.Period.allCases, id: \.self) { period in
                    if let fraction = budgets.fraction(for: period), let limit = budgets.limit(for: period) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(period.title): \(Fmt.money(budgets.spend(for: period))) of \(Fmt.money(limit))")
                                    .font(.system(size: 11))
                                Spacer()
                                Text(Fmt.percent(fraction))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(fraction >= 1 ? .orange : .secondary)
                                    .monospacedDigit()
                            }
                            ShareBar(fraction: fraction, color: fraction >= 1 ? .orange : Palette.accent)
                        }
                        .padding(.top, 2)
                    }
                }
            }

            SettingsSection(
                title: "Alerts",
                footnote: """
                    Each threshold notifies at most once per period, and the fact that \
                    it fired is remembered across relaunches — so a budget you have \
                    already blown past will not nag you every time the app starts.
                    """
            ) {
                Toggle("Notify me when a budget is approached or exceeded", isOn: $budgets.notificationsEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!budgets.isActive)

                HStack(spacing: 8) {
                    Text("Warn at")
                        .font(.system(size: 11))
                    Slider(value: $budgets.warningThreshold, in: 0.5...0.95, step: 0.05)
                        .frame(width: 180)
                    Text(Fmt.percent(budgets.warningThreshold))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .leading)
                }
                .disabled(!budgets.notificationsEnabled)

                if budgets.authorizationDenied {
                    Label(
                        "macOS is blocking notifications for TokenCounter. Enable them in System Settings › Notifications.",
                        systemImage: "bell.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("Let alerts fire again this period") { budgets.resetNotificationHistory() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!budgets.notificationsEnabled)
            }
        }
    }
}

// MARK: - History

private struct HistorySettings: View {
    @Bindable var store: UsageStore
    @Bindable var archive: UsageArchive

    @State private var confirmingClear = false

    var body: some View {
        Pane {
            SettingsSection(
                title: "Keep usage history",
                footnote: """
                    Claude Code prunes its own logs. With this on, responses are mirrored \
                    into one file per month under Application Support and merged back in \
                    at launch, so deleting a session log no longer erases its spend. \
                    Only token counts are stored — never dollars — so history re-prices \
                    itself whenever rates change.
                    """
            ) {
                Toggle("Keep a local copy of usage history", isOn: $archive.isEnabled)
                    .toggleStyle(.checkbox)

                if archive.isEnabled {
                    Text("\(Fmt.integer(archive.recordCount)) responses · \(sizeText) on disk")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if store.archivedRecordCount > 0 {
                        Text("\(Fmt.integer(store.archivedRecordCount)) of those are no longer in the logs.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if archive.isReadOnly && archive.isEnabled {
                    Label(
                        "Another copy of TokenCounter has the history open, so this one is only reading it.",
                        systemImage: "lock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !archive.quarantined.isEmpty {
                    Label(
                        "\(archive.quarantined.count) damaged file(s) were set aside, not deleted: "
                            + archive.quarantined.joined(separator: ", "),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "Stored files") {
                HStack {
                    Text(AppPaths.archive.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.archive])
                    }
                }

                if confirmingClear {
                    HStack(spacing: 8) {
                        Text("Delete all stored history? Responses whose logs are gone cannot be recovered.")
                            .font(.caption)
                        Button("Delete") {
                            archive.clear()
                            confirmingClear = false
                            store.reloadFromScratch()
                        }
                        Button("Cancel") { confirmingClear = false }
                    }
                } else {
                    Button("Delete stored history…") { confirmingClear = true }
                        .disabled(!archive.isEnabled || archive.recordCount == 0)
                }
            }
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: archive.diskSize, countStyle: .file)
    }
}
