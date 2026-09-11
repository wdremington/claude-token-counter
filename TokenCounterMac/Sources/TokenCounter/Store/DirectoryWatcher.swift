import CoreServices
import Foundation

/// Watches a directory tree and reports coalesced change notifications.
///
/// The handler runs on a private queue, so callers are responsible for hopping
/// to whatever actor they need.
final class DirectoryWatcher {
    private let url: URL
    private let handler: () -> Void
    private let queue = DispatchQueue(label: "com.tokencounter.fsevents")
    private var stream: FSEventStreamRef?

    /// Seconds FSEvents batches changes before delivering them.
    private let latency: CFTimeInterval = 1.0

    init(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: url.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func fire() { handler() }
}

private func fsEventsCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().fire()
}
