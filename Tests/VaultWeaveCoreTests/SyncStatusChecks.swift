import Foundation
import VaultWeaveCore

extension EngineTests {
    func testIgnoredFilesNeverHideSiblingsOrPublishDeletions() throws {
        let a = try node("a", syncSettings: true), b = try node("b", syncSettings: true)
        try write(a, "metadata", path: ".DS_Store")
        try write(a, "root note", path: "root.md")
        for index in 0..<16 {
            let directory = "folder-\(index)"
            try write(a, "metadata", path: directory+"/.DS_Store")
            try write(a, "note", path: directory+"/note.md")
            try write(a, "image", path: directory+"/image.svg")
            try write(a, "temporary", path: directory+"/download.tmp")
        }
        try write(a, "layout", path: ".obsidian/workspace.json")
        try write(a, "settings", path: ".obsidian/app.json")
        checkEqual(try a.scan().files, 34)
        try exchange(a, b)
        checkEqual(try b.scan().files, 34)
        checkEqual(try b.scan().files, 34)
        checkEqual(try a.scan().files, 34)
        let revisions = try b.store.load().revisions.values
        checkFalse(revisions.contains { $0.payload.blob == nil })
        checkEqual(try read(b, path: "folder-15/note.md"), "note")
        checkFalse(FileManager.default.fileExists(atPath: b.mapping.path+"/.DS_Store"))
    }
    func testCancelledScanPreservesLocalAndRemoteWork() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "base"); _ = try a.scan(); try exchange(a, b); _ = try b.scan()
        try write(a, "remote update"); _ = try a.scan(); try exchange(a, b)
        try write(b, "local edit")
        let control = ScanControl(); control.cancel()
        checkThrows(try b.scan(control: control))
        checkEqual(try read(b), "local edit")
        let report = try b.scan()
        checkEqual(report.conflicts.count, 1)
        let values = try report.conflicts[0].heads.compactMap { try b.content($0) }
        checkTrue(values.contains(Data("remote update".utf8)))
        checkTrue(values.contains(Data("local edit".utf8)))
        checkEqual(try read(b), "local edit")
    }
    func testTransferStatusSeparatesReceivingAndComplete() throws {
        func status(bytes: Int, need: Int, files: Int) throws -> TransportStatus {
            let value: [String: Any] = ["state":"syncing","globalFiles":3,"globalBytes":bytes,"needBytes":need,"needFiles":files,"errors":0,"pullErrors":0]
            return try JSONDecoder().decode(TransportStatus.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let receiving = try status(bytes: 1000, need: 300, files: 2)
        checkTrue(receiving.isReceiving); checkEqual(receiving.fractionReceived, 0.7)
        let metadata = try status(bytes: 0, need: 0, files: 1)
        checkTrue(metadata.isReceiving); checkEqual(metadata.fractionReceived, 0)
        let complete = try status(bytes: 1000, need: 0, files: 0)
        checkFalse(complete.isReceiving); checkEqual(complete.fractionReceived, 1)
        checkEqual(try status(bytes: 100, need: 200, files: 3).fractionReceived, 0)
    }
}
