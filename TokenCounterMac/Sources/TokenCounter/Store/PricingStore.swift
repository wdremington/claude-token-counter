import Foundation
import Observation

/// Owns the rates the app prices with, resolved from three layers.
///
/// Highest priority first: the user's own overrides, then a catalog refreshed
/// over the network, then the table compiled into the app. Layers merge **per
/// entry**, so overriding one model does not hide the rest of the table, and the
/// bundled floor means the app is fully correct with networking switched off.
///
/// Nothing here talks to an Anthropic API. The refresh is one anonymous GET for
/// a static file; no credentials are sent and no usage data leaves the machine.
@MainActor
@Observable
final class PricingStore {

    /// The static catalog this build refreshes from.
    ///
    /// Leave empty to disable the network path entirely - the app then runs on
    /// the bundled table plus whatever the user has typed, which is a complete
    /// and supported configuration.
    static let catalogURL: URL? = nil

    struct Override: Codable, Equatable {
        var enabled: Bool = true
        var rate: ModelRate
    }

    // MARK: - State

    private(set) var pricer: Pricer
    private(set) var remote: PricingCatalog?
    private(set) var overrides: [String: Override]

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var lastRefreshError: String?

    var autoRefresh: Bool {
        didSet { guard autoRefresh != oldValue else { return }; persist() }
    }

    /// Fired whenever the resolved rates change. Deliberately a plain callback
    /// rather than observation tracking: the recompute it drives must happen
    /// exactly once, synchronously, on the main actor.
    var onChange: (() -> Void)?

    var isNetworkConfigured: Bool { Self.catalogURL != nil }

    /// Shown in Settings as "rates as of".
    var catalogDate: String? { remote?.updated ?? Pricing.bundled.updated }

    // MARK: - Lifecycle

    init(bundledOnly: Bool = false) {
        let defaults = UserDefaults.standard
        autoRefresh = defaults.object(forKey: Key.autoRefresh) as? Bool ?? true

        let loadedOverrides = bundledOnly ? [:] : Self.loadOverrides()
        let loadedRemote = bundledOnly ? nil : Self.loadCachedRemote()
        if !bundledOnly { lastRefresh = defaults.object(forKey: Key.lastRefresh) as? Date }

        overrides = loadedOverrides
        remote = loadedRemote
        pricer = Self.makePricer(remote: loadedRemote, overrides: loadedOverrides)
    }

    private static func makePricer(remote: PricingCatalog?, overrides: [String: Override]) -> Pricer {
        var layers = [Pricing.bundled]
        if let remote { layers.append(remote) }

        let active = overrides.filter(\.value.enabled)
        if !active.isEmpty {
            layers.append(PricingCatalog(
                updated: nil,
                entries: active
                    .map { PricingCatalog.Entry(id: $0.key, displayName: nil, rate: $0.value.rate) }
                    .sorted { $0.id < $1.id }
            ))
        }
        return Pricer(layers: layers)
    }

    private func rebuild() {
        pricer = Self.makePricer(remote: remote, overrides: overrides)
        onChange?()
    }

    // MARK: - Overrides

    func setOverride(_ rate: ModelRate, for model: String) {
        let id = ContextTier.split(model).id
        guard !id.isEmpty else { return }
        overrides[id] = Override(enabled: true, rate: rate)
        persistOverrides()
        rebuild()
    }

    func setOverrideEnabled(_ enabled: Bool, for model: String) {
        let id = ContextTier.split(model).id
        guard var existing = overrides[id], existing.enabled != enabled else { return }
        existing.enabled = enabled
        overrides[id] = existing
        persistOverrides()
        rebuild()
    }

    func removeOverride(for model: String) {
        let id = ContextTier.split(model).id
        guard overrides.removeValue(forKey: id) != nil else { return }
        persistOverrides()
        rebuild()
    }

    /// The rate an override editor should start from: whatever is in effect now.
    func effectiveRate(for model: String) -> ModelRate? {
        pricer.rate(for: model)
    }

    // MARK: - Refresh

    /// Best-effort. Any failure keeps the last good catalog - a rate table is
    /// never worse for being slightly old, and is much worse for being garbage.
    func refresh(force: Bool = false) async {
        guard let url = Self.catalogURL, !isRefreshing, force || autoRefresh else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastRefreshError = "Server returned an unexpected response."
                return
            }
            guard let catalog = PricingCatalog.validated(data) else {
                lastRefreshError = "The downloaded rate table was rejected as invalid."
                return
            }

            AppPaths.ensure(AppPaths.support)
            try? data.write(to: AppPaths.remotePricing, options: .atomic)

            remote = catalog
            lastRefresh = Date()
            UserDefaults.standard.set(lastRefresh, forKey: Key.lastRefresh)
            rebuild()
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    func clearRemoteCatalog() {
        try? FileManager.default.removeItem(at: AppPaths.remotePricing)
        remote = nil
        lastRefresh = nil
        UserDefaults.standard.removeObject(forKey: Key.lastRefresh)
        rebuild()
    }

    // MARK: - Persistence

    private enum Key {
        static let overrides = "pricing.overrides"
        static let autoRefresh = "pricing.autoRefresh"
        static let lastRefresh = "pricing.lastRefresh"
    }

    private static func loadCachedRemote() -> PricingCatalog? {
        guard let data = try? Data(contentsOf: AppPaths.remotePricing) else { return nil }
        return PricingCatalog.validated(data)
    }

    private static func loadOverrides() -> [String: Override] {
        guard let data = UserDefaults.standard.data(forKey: Key.overrides),
              let decoded = try? JSONDecoder().decode([String: Override].self, from: data)
        else { return [:] }
        // A hand-edited defaults plist is still user input; drop anything that
        // would price absurdly rather than trusting it.
        return decoded.filter {
            PricingCatalog(entries: [.init(id: $0.key, displayName: nil, rate: $0.value.rate)]).isValid
        }
    }

    private func persistOverrides() {
        let data = try? JSONEncoder().encode(overrides)
        UserDefaults.standard.set(data, forKey: Key.overrides)
    }

    private func persist() {
        UserDefaults.standard.set(autoRefresh, forKey: Key.autoRefresh)
    }
}
