import Foundation

/// Only immutable, verified objects live here. Never share LocalState or a live database.
public final class ObjectStore {
    public let root: URL
    public let vaultID: String
    private let fm = FileManager.default
    private var revisionIndex: [String: Revision] = [:]
    private var revisionErrors: [String: String] = [:]
    private var blobChecks: [String: Bool] = [:]
    private var pendingWrites = Set<String>()
    private var graph: (revisions: [String: Revision], notices: [String])?
    public init(transportRoot: URL, vaultID: String) throws {
        guard Codec.validVaultID(vaultID) else { throw VaultSyncError.invalidConfiguration("文库 ID 必须是 UUID。") }
        self.vaultID = vaultID
        root = try Codec.safeURL(root: transportRoot, path: vaultID)
        try fm.createDirectory(at: Codec.safeURL(root: root, path: "blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: Codec.safeURL(root: root, path: "revisions"), withIntermediateDirectories: true)
    }
    @discardableResult public func putBlob(_ data: Data) throws -> String {
        let id = Codec.hash(data)
        try put(data, at: root.appendingPathComponent("blobs/\(id)"))
        return id
    }
    public func blob(_ id: String) throws -> Data {
        guard Codec.validID(id) else { throw VaultSyncError.invalidObject(id) }
        let url = try Codec.safeURL(root: root, path: "blobs/\(id)")
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw VaultSyncError.invalidObject(id)
        }
        let data = try Data(contentsOf: url)
        guard Codec.hash(data) == id else { throw VaultSyncError.invalidObject(id) }
        return data
    }
    @discardableResult public func create(path: String, parents: [String], data: Data?, device: String, timestamp: Double? = nil) throws -> Revision {
        try Codec.validatePath(path)
        let payload = RevisionPayload(vaultID: vaultID, path: path, parents: Array(Set(parents)).sorted(),
                                      blob: try data.map(putBlob), device: device, timestamp: timestamp ?? Date().timeIntervalSince1970)
        let revision = try Revision(payload: payload)
        try revision.validate(vaultID: vaultID)
        try put(Codec.encode(revision), at: root.appendingPathComponent("revisions/\(revision.id).json"))
        return revision
    }
    private func put(_ data: Data, at url: URL) throws {
        let safe = try Codec.safeURL(root: root, path: String(url.path.dropFirst(root.path.count + 1)))
        if fm.fileExists(atPath: safe.path) {
            guard try Data(contentsOf: safe) == data else { throw VaultSyncError.invalidObject(safe.lastPathComponent) }
        } else {
            try data.write(to: safe, options: .atomic)
            pendingWrites.insert(String(safe.path.dropFirst(root.path.count + 1)))
        }
    }
    /// Parents and payloads may arrive in any order. Incomplete branches never become applicable heads.
    public func load(changes: FileChanges? = nil, control: ScanControl? = nil) throws -> (revisions: [String: Revision], notices: [String]) {
        try control?.check()
        let full = graph == nil || changes == nil || !(changes?.directories.isEmpty ?? true)
        let directory = try Codec.safeURL(root: root, path: "revisions")
        let changed = (changes?.files ?? []).union(pendingWrites)
        if !full && changed.isEmpty, let graph { return graph }

        var revisions = full ? [:] : revisionIndex
        var errors = full ? [:] : revisionErrors
        var checks = full ? [:] : blobChecks
        let revisionFiles: [URL]
        if full {
            revisionFiles = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        } else {
            var affectedRevisions: [URL] = []
            for path in changed {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let name = String(parts[1])
                if parts[0] == "revisions", name.hasSuffix(".json"), Codec.validID(String(name.dropLast(5))) {
                    affectedRevisions.append(directory.appendingPathComponent(name, isDirectory: false))
                } else if parts[0] == "blobs", Codec.validID(name) {
                    checks.removeValue(forKey: name)
                }
            }
            revisionFiles = affectedRevisions
        }

        for url in revisionFiles where url.pathExtension == "json" {
            try control?.check()
            let filename = url.lastPathComponent
            revisions.removeValue(forKey: filename)
            errors.removeValue(forKey: filename)
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw VaultSyncError.invalidPath(filename)
                }
                let revision = try JSONDecoder().decode(Revision.self, from: Data(contentsOf: url))
                try revision.validate(vaultID: vaultID)
                guard url.deletingPathExtension().lastPathComponent == revision.id else {
                    throw VaultSyncError.invalidObject(filename)
                }
                revisions[filename] = revision
            } catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain ||
                    ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                    errors[filename] = "等待或拒绝对象 \(filename.prefix(12))：\(error.localizedDescription)"
                }
            }
        }

        var candidates: [String: Revision] = [:]
        var notices = Array(errors.values)
        for (filename, revision) in revisions {
            try control?.check()
            if let id = revision.payload.blob {
                if checks[id] == nil {
                    checks[id] = (try? blob(id)) != nil
                }
                guard checks[id] == true else {
                    notices.append("等待或拒绝对象 \(filename.prefix(12))：版本内容缺失或校验失败。")
                    continue
                }
            }
            candidates[revision.id] = revision
        }
        var ready: [String: Revision] = [:], pendingCounts: [String: Int] = [:], children: [String: [String]] = [:]
        var queue: [String] = []
        for (id, revision) in candidates {
            guard revision.payload.parents.allSatisfy({ candidates[$0]?.payload.path == revision.payload.path }) else { continue }
            pendingCounts[id] = revision.payload.parents.count
            if revision.payload.parents.isEmpty { queue.append(id) }
            for parent in revision.payload.parents { children[parent, default: []].append(id) }
        }
        while let id = queue.popLast() {
            ready[id] = candidates[id]
            for child in children[id] ?? [] { pendingCounts[child, default: 0] -= 1; if pendingCounts[child] == 0 { queue.append(child) } }
        }
        try control?.check()
        if ready.count != candidates.count { notices.append("\(candidates.count - ready.count) 个版本正在等待完整的父版本。") }
        revisionIndex = revisions
        revisionErrors = errors
        blobChecks = checks
        pendingWrites.removeAll()
        graph = (ready, notices)
        return (ready, notices)
    }
    public static func heads(path: String, revisions: [String: Revision]) -> [Revision] {
        let nodes = revisions.values.filter { $0.payload.path == path }
        return heads(nodes: Array(nodes))
    }
    public static func heads(nodes: [Revision]) -> [Revision] {
        let parents = Set(nodes.flatMap { $0.payload.parents })
        return nodes.filter { !parents.contains($0.id) }.sorted { $0.id < $1.id }
    }
    public static func commonBase(_ heads: [Revision], revisions: [String: Revision]) -> Revision? {
        guard !heads.isEmpty else { return nil }
        func ancestors(_ id: String) -> Set<String> {
            var result = Set<String>(), pending = [id]
            while let next = pending.popLast() {
                if result.insert(next).inserted { pending += revisions[next]?.payload.parents ?? [] }
            }
            return result
        }
        var common = ancestors(heads[0].id)
        for head in heads.dropFirst() { common.formIntersection(ancestors(head.id)) }
        // Multiple best bases (criss-cross merges) need explicit manual resolution.
        let best = common.filter { candidate in !common.contains { $0 != candidate && ancestors($0).contains(candidate) } }
        return best.count == 1 ? revisions[best.first!] : nil
    }
}
