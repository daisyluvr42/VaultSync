import Darwin
import Foundation

/// Serialized by its caller. Capture local changes before incorporating remote branches.
public final class VaultEngine {
    public let mapping: VaultMapping
    public let store: ObjectStore
    public let device: String
    private let stateURL: URL
    private var state: LocalState
    private let fm = FileManager.default
    private struct Stamp: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec
        var changed: timespec

        static func == (lhs: Stamp, rhs: Stamp) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }
    private let vault: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t
    private var stamps: [String: Stamp] = [:]
    private var hasBaseline = false
    public init(mapping: VaultMapping, transportRoot: URL, stateRoot: URL, device: String) throws {
        self.mapping = mapping; self.device = device
        let vault = URL(fileURLWithPath: mapping.path).standardizedFileURL.resolvingSymlinksInPath()
        let transport = transportRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let info = try Self.fileInfo(vault), info.st_mode & S_IFMT == S_IFDIR,
              vault.path != "/", vault.path != transport.path,
              !transport.path.hasPrefix(vault.path + "/"), !vault.path.hasPrefix(transport.path + "/") else {
            throw WeaveError.invalidConfiguration("文库必须存在，且不能与版本传输目录重叠。")
        }
        self.vault = vault
        rootDevice = info.st_dev
        rootInode = info.st_ino
        store = try ObjectStore(transportRoot: transport, vaultID: mapping.id)
        try fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        stateURL = stateRoot.appendingPathComponent(mapping.id + ".json")
        if fm.fileExists(atPath: stateURL.path) {
            state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: stateURL))
            if let oldPath = state.rootPath, oldPath != vault.path { state = LocalState(rootPath: vault.path) }
        } else { state = LocalState() }
        state.rootPath = vault.path
    }
    private static func fileInfo(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func checkRoot() throws {
        guard let info = try Self.fileInfo(vault), info.st_dev == rootDevice, info.st_ino == rootInode,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw WeaveError.invalidConfiguration("文库暂时不可用或已被替换，已暂停扫描，避免误判为批量删除。")
        }
    }
    private func save() throws { try Codec.encode(state).write(to: stateURL, options: .atomic) }
    private func data(at path: String) throws -> Data? {
        let url = try Codec.safeURL(root: vault, path: path)
        guard let info = try Self.fileInfo(url) else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WeaveError.invalidPath(path) }
        return try Data(contentsOf: url)
    }
    private func localFiles(in directory: URL, control: ScanControl?) throws -> Set<String> {
        let root = vault
        var failure: Error?
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                                        errorHandler: { _, error in failure = error; return false }) else { throw WeaveError.invalidPath(root.path) }
        var paths = Set<String>()
        for case let url as URL in walker {
            try control?.check()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { if values.isDirectory == true { walker.skipDescendants() }; continue }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard normalized.hasPrefix(root.path + "/") else { throw WeaveError.invalidPath(url.path) }
            let path = String(normalized.dropFirst(root.path.count + 1))
            // skipDescendants on a regular file skips the remainder of its directory on macOS.
            // That turns existing, unvisited siblings into false deletions during capture.
            if !mapping.includes(path) { if values.isDirectory == true { walker.skipDescendants() }; continue }
            if values.isRegularFile == true { try Codec.validatePath(path); paths.insert(path) }
        }
        if let failure { throw failure }
        return paths
    }
    private func stamp(_ path: String) throws -> Stamp? {
        let url = try Codec.safeURL(root: vault, path: path)
        guard let info = try Self.fileInfo(url) else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WeaveError.invalidPath(path) }
        return Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modified: info.st_mtimespec, changed: info.st_ctimespec)
    }

    private func changedFiles(_ changes: FileChanges, control: ScanControl?) throws -> (present: Set<String>, paths: Set<String>) {
        var present = Set<String>()
        var paths = Set<String>()
        var directoryNames: [String: Set<String>] = [:]
        let directories = changes.directories.filter(mapping.includes)
        let scopes = Set(directories.filter { path in
            !directories.contains { path.hasPrefix($0 + "/") }
        })
        let files = changes.files.filter { path in
            mapping.includes(path) && !scopes.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        for path in scopes.union(files) {
            try control?.check()
            let url = try Codec.safeURL(root: vault, path: path)
            let parent = url.deletingLastPathComponent().path
            if directoryNames[parent] == nil {
                // Use the directory's exact spelling so a case-only rename records both sides.
                let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
                if let info = try Self.fileInfo(parentURL), info.st_mode & S_IFMT == S_IFDIR {
                    directoryNames[parent] = Set(try fm.contentsOfDirectory(atPath: parent))
                } else {
                    directoryNames[parent] = []
                }
            }
            if scopes.contains(path) {
                paths.formUnion(state.files.keys.filter { $0 == path || $0.hasPrefix(path + "/") })
            }
            paths.insert(path)
            guard directoryNames[parent]?.contains(url.lastPathComponent) == true,
                  let info = try Self.fileInfo(url) else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                paths.formUnion(state.files.keys.filter { $0.hasPrefix(path + "/") })
                present.formUnion(try localFiles(in: url, control: control))
            } else if info.st_mode & S_IFMT == S_IFREG {
                present.insert(path)
            }
        }
        return (present, paths.union(present))
    }

    private func capture(changes: FileChanges? = nil, control: ScanControl? = nil) throws {
        try control?.check()
        try checkRoot()
        let diskPaths: Set<String>
        let paths: Set<String>
        if let changes {
            (diskPaths, paths) = try changedFiles(changes, control: control)
        } else {
            diskPaths = try localFiles(in: vault, control: control)
            paths = diskPaths.union(state.files.keys.filter(mapping.includes))
        }
        try checkRoot()
        var dirty = false
        defer { if dirty { try? save() } }
        for path in paths.sorted() {
            try control?.check()
            let before = diskPaths.contains(path) ? try stamp(path) : nil
            if changes != nil, state.files[path] != nil, let before, stamps[path] == before { continue }
            if diskPaths.contains(path), before == nil { throw WeaveError.changedDuringSync(path) }
            let bytes = diskPaths.contains(path) ? try data(at: path) : nil, digest = bytes.map(Codec.hash)
            try control?.check()
            if diskPaths.contains(path) { guard try stamp(path) == before else { throw WeaveError.changedDuringSync(path) } }
            if let track = state.files[path] {
                if digest != track.blob {
                    try checkRoot()
                    let revision = try store.create(path: path, parents: track.heads, data: bytes, device: device)
                    state.files[path] = FileTrack(heads: [revision.id], blob: revision.payload.blob)
                    dirty = true
                }
            } else if bytes != nil {
                try checkRoot()
                let revision = try store.create(path: path, parents: [], data: bytes, device: device)
                state.files[path] = FileTrack(heads: [revision.id], blob: revision.payload.blob)
                dirty = true
            }
            stamps[path] = before
        }
        if dirty { try save(); dirty = false }
        if changes == nil { hasBaseline = true }
    }
    public func scan(changes: ScanChanges = .full, control: ScanControl? = nil) throws -> SyncReport {
        try capture(changes: hasBaseline ? changes.local : nil, control: control)
        let loaded = try store.load(changes: changes.objects, control: control)
        var report = SyncReport(); report.revisions = loaded.revisions.count; report.notices = loaded.notices
        let byPath = Dictionary(grouping: loaded.revisions.values, by: { $0.payload.path })
        let paths = byPath.keys.filter(mapping.includes).sorted()
        let pathHeads = byPath.mapValues { ObjectStore.heads(nodes: $0) }
        let occupied = paths.filter { pathHeads[$0]?.contains { $0.payload.blob != nil } == true }
        var blocked = Set<String>()
        let groups = Dictionary(grouping: occupied) { $0.precomposedStringWithCanonicalMapping.lowercased() }
        for group in groups.values where group.count > 1 { blocked.formUnion(group) }
        for path in occupied {
            let components = path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            var prefix = ""
            for component in components.dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + component
                if let parents = groups[prefix] { blocked.insert(path); blocked.formUnion(parents) }
            }
        }
        if !blocked.isEmpty { report.notices.append("路径大小写或文件/文件夹冲突，已保留版本并暂停这些路径：" + blocked.sorted().joined(separator: "、")) }
        for path in paths {
            try control?.check()
            if blocked.contains(path) { continue }
            if let track = state.files[path], !track.heads.allSatisfy({ loaded.revisions[$0] != nil }) {
                report.notices.append("\(path) 的本地父版本尚不完整，暂缓应用更新。")
                continue
            }
            var heads = pathHeads[path] ?? []
            if heads.count > 1 && Set(heads.map { $0.payload.blob }).count == 1 {
                let bytes = try heads[0].payload.blob.map(store.blob)
                try control?.check()
                let joined = try store.create(path: path, parents: heads.map(\.id), data: bytes, device: "VaultWeave · identical content",
                                              timestamp: heads.map { $0.payload.timestamp }.max())
                heads = [joined]
            }
            if heads.count == 1 {
                if state.files[path]?.heads == [heads[0].id] { continue }
                do { try apply(heads[0], control: control) } catch WeaveError.changedDuringSync {
                    report.notices.append("\(path) 正在编辑，下次扫描重试。")
                }
            } else if heads.count > 1 {
                report.conflicts.append(FileConflict(path: path, heads: heads,
                                                    base: ObjectStore.commonBase(heads, revisions: loaded.revisions)))
            }
        }
        report.files = state.files.values.filter { $0.blob != nil }.count
        return report
    }
    private func apply(_ revision: Revision, control: ScanControl? = nil) throws {
        try control?.check()
        let path = revision.payload.path
        try checkRoot()
        let url = try Codec.safeURL(root: vault, path: path)
        let current = try data(at: path)
        try control?.check()
        let expected = state.files[path]?.blob
        guard current.map(Codec.hash) == expected else { throw WeaveError.changedDuringSync(path) }
        if current.map(Codec.hash) != revision.payload.blob {
            if let blob = revision.payload.blob {
                let bytes = try store.blob(blob)
                try control?.check()
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Recheck after fetching the blob; normal editor writes during preparation defer the update.
                guard try data(at: path).map(Codec.hash) == expected else { throw WeaveError.changedDuringSync(path) }
                try bytes.write(to: url, options: .atomic)
            } else if current != nil { try fm.removeItem(at: url) }
        }
        state.files[path] = FileTrack(heads: [revision.id], blob: revision.payload.blob)
        try save()
    }
    public func resolve(path: String, expectedHeads: [String], data: Data?) throws -> SyncReport {
        try capture()
        let loaded = try store.load()
        let heads = ObjectStore.heads(path: path, revisions: loaded.revisions)
        guard heads.map(\.id).sorted() == expectedHeads.sorted(), heads.count > 1 else { throw WeaveError.staleMerge }
        let revision = try store.create(path: path, parents: heads.map(\.id), data: data, device: device)
        try apply(revision)
        return try scan(changes: ScanChanges())
    }
    public func content(_ revision: Revision) throws -> Data? { try revision.payload.blob.map(store.blob) }
    public func history(path: String) throws -> [Revision] {
        try store.load().revisions.values.filter { $0.payload.path == path }.sorted { $0.payload.timestamp > $1.payload.timestamp }
    }
    public func restore(_ revision: Revision) throws -> SyncReport {
        try capture()
        let graph = try store.load().revisions
        let heads = ObjectStore.heads(path: revision.payload.path, revisions: graph)
        guard heads.count == 1 else { throw WeaveError.staleMerge }
        let restored = try store.create(path: revision.payload.path, parents: heads.map(\.id), data: content(revision), device: device)
        try apply(restored)
        return try scan(changes: ScanChanges())
    }
}
