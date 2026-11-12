import Foundation

public struct MergePreview {
    public var text: String
    public var hasConflicts: Bool
}
public enum TextMerge {
    public static func preview(base: Data, versions: [Data]) throws -> MergePreview {
        guard !versions.isEmpty, ([base] + versions).allSatisfy({ String(data: $0, encoding: .utf8) != nil && !$0.contains(0) }) else { throw VaultSyncError.binaryFile }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VaultSync-merge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var result = versions[0]
        for (offset, next) in versions.dropFirst().enumerated() {
            let ours = temp.appendingPathComponent("ours"), ancestor = temp.appendingPathComponent("base"), theirs = temp.appendingPathComponent("theirs")
            try result.write(to: ours); try base.write(to: ancestor); try next.write(to: theirs)
            let output = temp.appendingPathComponent("result")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/diff3")
            process.arguments = ["-m", "-L", "已合并版本", "-L", "共同祖先", "-L", "另一设备", ours.path, ancestor.path, theirs.path]
            process.standardOutput = handle; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus <= 1 else { throw VaultSyncError.invalidConfiguration("diff3 无法生成合并预览。") }
            result = try Data(contentsOf: output)
            if process.terminationStatus == 1 {
                guard offset == versions.count - 2 else { throw VaultSyncError.invalidConfiguration("多分支合并存在重叠，请比较全部分支后手动编辑结果。") }
                return MergePreview(text: String(decoding: result, as: UTF8.self), hasConflicts: true)
            }
        }
        return MergePreview(text: String(decoding: result, as: UTF8.self), hasConflicts: false)
    }
    public static func diff(_ lhs: Data, _ rhs: Data) throws -> String {
        guard String(data: lhs, encoding: .utf8) != nil, String(data: rhs, encoding: .utf8) != nil,
              !lhs.contains(0), !rhs.contains(0) else { throw VaultSyncError.binaryFile }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VaultSync-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let a = temp.appendingPathComponent("a"), b = temp.appendingPathComponent("b"), out = temp.appendingPathComponent("out")
        try lhs.write(to: a); try rhs.write(to: b)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", "-L", "版本 A", "-L", "版本 B", a.path, b.path]
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus <= 1 else { throw VaultSyncError.invalidConfiguration("diff 无法读取文件。") }
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }
}
