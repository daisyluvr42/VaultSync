import Foundation
import CryptoKit

public enum WeaveError: LocalizedError {
    case invalidPath(String), invalidObject(String), staleMerge, changedDuringSync(String)
    case binaryFile, missingBase, invalidConfiguration(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let p): return "拒绝不安全的路径：\(p)"
        case .invalidObject(let p): return "版本对象校验失败：\(p)"
        case .staleMerge: return "版本已变化，请重新载入差异后合并。你的合并草稿已保留。"
        case .changedDuringSync(let p): return "文件正在被编辑，已推迟更新：\(p)"
        case .binaryFile: return "该文件不是 UTF-8 文本，请选择保留某个版本。"
        case .missingBase: return "没有唯一的共同祖先，请手动比较并合并。"
        case .invalidConfiguration(let s): return s
        }
    }
}

public enum Codec {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func validID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) }
    }
    public static func validVaultID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WeaveError.invalidPath(path) }
    }
    public static func safeURL(root: URL, path: String) throws -> URL {
        try validatePath(path)
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw WeaveError.invalidPath(path)
            }
        }
        guard cursor.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw WeaveError.invalidPath(path) }
        return cursor
    }
}

public struct VaultMapping: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var syncSettings: Bool
    public init(id: String = UUID().uuidString.lowercased(), name: String, path: String, syncSettings: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.syncSettings = syncSettings
    }
    public func includes(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        if [".git", ".trash", ".stfolder", ".stversions", ".vaultweave"].contains(first) { return false }
        if first == ".obsidian" {
            guard syncSettings else { return false }
            if parts.count == 2 && ["workspace.json", "workspace-mobile.json", "workspaces.json"].contains(parts[1]) { return false }
        } else if first.hasPrefix(".") { return false }
        return !parts.contains(".DS_Store") && !parts.contains(where: {
            $0.hasPrefix(".syncthing.") || $0.hasPrefix(".dat.nosync") || $0.hasSuffix(".tmp")
        })
    }
}

public struct RevisionPayload: Sendable, Codable, Equatable {
    public var schema: Int = 1
    public var vaultID: String
    public var path: String
    public var parents: [String]
    public var blob: String?
    public var device: String
    public var timestamp: Double
}

public struct Revision: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var payload: RevisionPayload
    public init(payload: RevisionPayload) throws { self.payload = payload; id = Codec.hash(try Codec.encode(payload)) }
    public func validate(vaultID: String) throws {
        try Codec.validatePath(payload.path)
        guard payload.schema == 1, payload.vaultID == vaultID,
              Codec.validID(id), id == Codec.hash(try Codec.encode(payload)),
              payload.parents.allSatisfy(Codec.validID), Set(payload.parents).count == payload.parents.count,
              payload.parents == payload.parents.sorted(),
              payload.blob.map(Codec.validID) ?? true,
              payload.timestamp.isFinite else { throw WeaveError.invalidObject(id) }
    }
}

public struct FileTrack: Sendable, Codable {
    public var heads: [String]
    public var blob: String?
    public init(heads: [String], blob: String?) { self.heads = heads; self.blob = blob }
}
public struct LocalState: Sendable, Codable {
    public var rootPath: String?
    public var files: [String: FileTrack] = [:]
    public init(rootPath: String? = nil) { self.rootPath = rootPath }
}
public struct FileConflict: Sendable, Identifiable, Equatable {
    public var path: String
    public var heads: [Revision]
    public var base: Revision?
    public var id: String { path }
}
public struct SyncReport: Sendable {
    public var files: Int = 0
    public var revisions: Int = 0
    public var conflicts: [FileConflict] = []
    public var notices: [String] = []
    public init() {}
}
