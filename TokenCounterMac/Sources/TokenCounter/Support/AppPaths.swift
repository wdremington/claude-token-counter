import Foundation

/// Where the app keeps the things it owns.
///
/// Everything lives under one directory so the Homebrew cask's `zap` stanza can
/// remove it in a single line.
enum AppPaths {
    static let directoryName = "TokenCounter"

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Last good copy of the refreshed rate catalog.
    static var remotePricing: URL {
        support.appendingPathComponent("pricing-remote.json")
    }

    /// One JSON file per UTC month of usage history.
    static var archive: URL {
        support.appendingPathComponent("archive", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }
}
