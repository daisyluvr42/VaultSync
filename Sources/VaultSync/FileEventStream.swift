import CoreServices
import Darwin
import Foundation
import VaultSyncCore

/// A file-level FSEvents stream delivered on the main queue.
final class FileEventStream {
    private final class Receiver {
        let root: String
        let deliver: @MainActor (FileChanges?) -> Void

        init(root: String, deliver: @escaping @MainActor (FileChanges?) -> Void) {
            self.root = root
            self.deliver = deliver
        }

        @MainActor func receive(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>) {
            let lost = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            let structural = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
            let edits = structural | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod
            var changes = FileChanges()
            for (index, path) in paths.enumerated() {
                let flag = Int(flags[index])
                let coalesced = flag & kFSEventStreamEventFlagMustScanSubDirs != 0
                if flag & lost != 0 || path == root && coalesced {
                    deliver(nil)
                    return
                }
                guard path.hasPrefix(root + "/") else { continue }
                let relative = String(path.dropFirst(root.count + 1))
                if coalesced || flag & kFSEventStreamEventFlagItemIsDir != 0 {
                    if coalesced || flag & structural != 0 { changes.directories.insert(relative) }
                } else if flag & edits != 0 && flag & kFSEventStreamEventFlagItemIsSymlink == 0 {
                    changes.files.insert(relative)
                }
            }
            if !changes.isEmpty { deliver(changes) }
        }
    }

    private let stream: FSEventStreamRef

    init?(root: URL, deliver: @escaping @MainActor (FileChanges?) -> Void) {
        // FSEvents reports kernel paths such as /private/tmp even when Foundation shortens them.
        guard let resolved = realpath(root.path, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        let receiver = Receiver(root: path, deliver: deliver)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(receiver).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Receiver>.fromOpaque(info).retain()
                return info
            }, release: { info in
                if let info { Unmanaged<Receiver>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let options = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, info, _, rawPaths, flags, _ in
            guard let info else { return }
            let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: CFArray.self) as NSArray
            guard let paths = paths as? [String] else { return }
            MainActor.assumeIsolated { receiver.receive(paths: paths, flags: flags) }
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.75,
           FSEventStreamCreateFlags(options)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
