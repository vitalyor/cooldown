import CoreServices
import Foundation

extension Timer {
    /// A repeating timer the system may shift a little (a fifth of its interval, at most 10 s),
    /// so Cooldown's wake-ups are grouped with others' — fewer wake-ups, less energy.
    @discardableResult
    static func every(_ interval: TimeInterval, _ block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: block)
        timer.tolerance = min(interval * 0.2, 10)
        return timer
    }
}

/// Folders watched through FSEvents: macOS says when something in them changed, so nothing has
/// to be re-listed on a timer just in case. Changes are grouped over `latency` seconds.
final class FolderWatch {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init?(_ paths: [String], latency: TimeInterval, handler: @escaping () -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// One file watched for growth (appends) through a dispatch source; follows the file when it
/// is replaced or removed and created again.
final class FileGrowthWatch {
    private let url: URL
    private let handler: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(_ url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        open()
    }

    private func open() {
        source?.cancel()
        source = nil
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.handler()
            if events.contains(.delete) || events.contains(.rename) {
                // Rotated or removed: watch the new file under the same name.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.open() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
