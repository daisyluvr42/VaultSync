import Foundation
import VaultSyncCore

final class EngineTests: CheckSuite {
    var temp: URL!
    let vaultID = UUID().uuidString.lowercased()
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("VaultSync-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }
    func node(_ name: String, syncSettings: Bool = false) throws -> VaultEngine {
        let root = temp.appendingPathComponent(name)
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return try VaultEngine(mapping: VaultMapping(id: vaultID, name: name, path: vault.path, syncSettings: syncSettings),
                               transportRoot: root.appendingPathComponent("objects"), stateRoot: root.appendingPathComponent("state"), device: name)
    }
    func write(_ engine: VaultEngine, _ text: String, path: String = "note.md") throws {
        let url = URL(fileURLWithPath: engine.mapping.path).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ engine: VaultEngine, path: String = "note.md") throws -> String {
        try String(contentsOf: URL(fileURLWithPath: engine.mapping.path).appendingPathComponent(path), encoding: .utf8)
    }
    // Simulates transport's immutable object union without requiring a network or real notes.
    func exchange(_ source: VaultEngine, _ target: VaultEngine) throws {
        for folder in ["blobs", "revisions"] {
            for file in try FileManager.default.contentsOfDirectory(at: source.store.root.appendingPathComponent(folder), includingPropertiesForKeys: nil) {
                let destination = target.store.root.appendingPathComponent(folder).appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: file, to: destination) }
            }
        }
    }
    func testInitialSyncAndNestedAttachments() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "hello"); try write(a, "attachment", path: "assets/pdf.bin")
        _ = try a.scan(); try exchange(a, b)
        let report = try b.scan()
        checkEqual(try read(b), "hello"); checkEqual(report.files, 2)
        checkTrue(report.conflicts.isEmpty)
    }
    func testOfflineBranchesRetainBaseAndRequireExplicitMerge() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "base"); _ = try a.scan(); try exchange(a, b); _ = try b.scan()
        try write(a, "ours"); try write(b, "theirs")
        _ = try a.scan(); _ = try b.scan(); try exchange(a, b); try exchange(b, a)
        let conflict = try unwrap(a.scan().conflicts.first)
        checkEqual(conflict.heads.count, 2)
        checkEqual(try a.content(unwrap(conflict.base)), Data("base".utf8))
        checkEqual(try read(a), "ours"); checkEqual(try read(b), "theirs")
        let merged = try a.resolve(path: conflict.path, expectedHeads: conflict.heads.map(\.id), data: Data("ours + theirs".utf8))
        checkTrue(merged.conflicts.isEmpty)
        try exchange(a, b); checkTrue(try b.scan().conflicts.isEmpty)
        checkEqual(try read(b), "ours + theirs")
        checkEqual(try a.history(path: "note.md").count, 4)
    }
    func testFourNodesAndLateOfflineBranch() throws {
        let a = try node("a"), b = try node("b"), c = try node("c"), d = try node("d")
        try write(a, "base"); _ = try a.scan()
        for other in [b,c,d] { try exchange(a, other); _ = try other.scan() }
        for (node, value) in [(a,"A"),(b,"B"),(c,"C"),(d,"D")] { try write(node, value); _ = try node.scan() }
        try exchange(b,a); try exchange(c,a)
        let conflict = try unwrap(a.scan().conflicts.first)
        checkEqual(conflict.heads.count, 3)
        _ = try a.resolve(path: "note.md", expectedHeads: conflict.heads.map(\.id), data: Data("ABC".utf8))
        try exchange(d,a)
        let late = try unwrap(a.scan().conflicts.first)
        checkEqual(late.heads.count, 2)
        checkEqual(try a.content(unwrap(late.base)), Data("base".utf8))
        _ = try a.resolve(path: "note.md", expectedHeads: late.heads.map(\.id), data: Data("ABCD".utf8))
        for other in [b,c,d] { try exchange(a, other); checkTrue(try other.scan().conflicts.isEmpty); checkEqual(try read(other), "ABCD") }
    }
    func testLocalEditInvalidatesOpenMerge() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "A"); try write(b, "B")
        _ = try a.scan(); _ = try b.scan(); try exchange(b,a)
        let conflict = try unwrap(a.scan().conflicts.first)
        try write(a, "new local work")
        checkThrows(try a.resolve(path: "note.md", expectedHeads: conflict.heads.map(\.id), data: Data("obsolete".utf8)))
        checkEqual(try read(a), "new local work")
        checkEqual(try a.scan().conflicts.count, 1)
    }
    func testDeleteVsEditAndDeletePropagation() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "base"); _ = try a.scan(); try exchange(a,b); _ = try b.scan()
        try FileManager.default.removeItem(atPath: a.mapping.path + "/note.md")
        try write(b, "keep this edit"); _ = try a.scan(); _ = try b.scan(); try exchange(b,a)
        let conflict = try unwrap(a.scan().conflicts.first)
        checkTrue(conflict.heads.contains { $0.payload.blob == nil })
        _ = try a.resolve(path: "note.md", expectedHeads: conflict.heads.map(\.id), data: nil)
        try exchange(a,b); _ = try b.scan()
        checkFalse(FileManager.default.fileExists(atPath: b.mapping.path + "/note.md"))
        checkTrue(try b.history(path: "note.md").contains { $0.payload.blob == Codec.hash(Data("keep this edit".utf8)) })
    }
    func testIdenticalIndependentlyImportedContentCoalesces() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "same"); try write(b, "same")
        _ = try a.scan(); _ = try b.scan(); try exchange(a,b)
        checkTrue(try b.scan().conflicts.isEmpty)
        checkEqual(try read(b), "same")
    }
    func testRestartRetainsAncestry() throws {
        let a = try node("a"); try write(a, "one"); _ = try a.scan()
        let restarted = try node("a"); try write(restarted, "two"); _ = try restarted.scan()
        let history = try restarted.history(path: "note.md")
        checkEqual(history.count, 2)
        if history.count == 2 { checkEqual(history[0].payload.parents, [history[1].id]) }
    }
    func testHistoryRestoreCreatesNewRevision() throws {
        let a = try node("a"); try write(a, "one"); _ = try a.scan()
        let first = try unwrap(a.history(path: "note.md").first)
        try write(a, "two"); _ = try a.scan(); _ = try a.restore(first)
        checkEqual(try read(a), "one"); checkEqual(try a.history(path: "note.md").count, 3)
    }
    func testMissingVaultDoesNotBecomeMassDeletion() throws {
        let a = try node("a"); try write(a, "safe"); _ = try a.scan()
        try FileManager.default.moveItem(atPath: a.mapping.path, toPath: a.mapping.path + "-unmounted")
        checkThrows(try a.scan())
        checkEqual(try a.store.load().revisions.count, 1)
    }
    func testMissingParentAndBlobDoNotApplyPartialVersion() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "one"); _ = try a.scan(); try write(a, "two"); _ = try a.scan()
        let history = try a.history(path: "note.md")
        let tip = try unwrap(history.first)
        try FileManager.default.copyItem(at: a.store.root.appendingPathComponent("revisions/\(tip.id).json"),
                                        to: b.store.root.appendingPathComponent("revisions/\(tip.id).json"))
        checkEqual(try b.scan().files, 0)
        let blob = try unwrap(tip.payload.blob)
        try FileManager.default.copyItem(at: a.store.root.appendingPathComponent("blobs/\(blob)"), to: b.store.root.appendingPathComponent("blobs/\(blob)"))
        checkEqual(try b.scan().files, 0)
        try exchange(a,b); _ = try b.scan(); checkEqual(try read(b), "two")
    }
    func testPathTraversalSymlinkAndTamperedObjectRejected() throws {
        for path in ["../escape", "/absolute", "a/../../b", "a//b", "a\\b"] { checkThrows(try Codec.validatePath(path)) }
        let a = try node("a")
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: a.mapping.path + "/link", withDestinationPath: outside.path)
        checkThrows(try Codec.safeURL(root: URL(fileURLWithPath: a.mapping.path), path: "link/escape.md"))
        let revision = try a.store.create(path: "note.md", parents: [], data: Data("safe".utf8), device: "a")
        try Data("tampered".utf8).write(to: a.store.root.appendingPathComponent("blobs/\(revision.payload.blob!)"))
        checkTrue(try a.store.load().revisions.isEmpty)
        checkFalse(try a.store.load().notices.isEmpty)
    }
    func testWorkspaceAndGitIgnored() throws {
        var mapping = VaultMapping(name: "x", path: temp.path)
        checkFalse(mapping.includes(".obsidian/app.json")); mapping.syncSettings = true
        checkTrue(mapping.includes(".obsidian/app.json"))
        checkFalse(mapping.includes(".obsidian/workspace.json"))
        checkFalse(mapping.includes(".git/HEAD")); checkTrue(mapping.includes("assets/test.png"))
    }
    func testCleanThreeWayMergeAndOverlappingConflict() throws {
        let base = Data("title\n\none\n\nend\n".utf8)
        let ours = Data("new title\n\none\n\nend\n".utf8)
        let theirs = Data("title\n\none\n\nnew end\n".utf8)
        let preview = try TextMerge.preview(base: base, versions: [ours,theirs])
        checkFalse(preview.hasConflicts); checkEqual(preview.text, "new title\n\none\n\nnew end\n")
        let overlap = try TextMerge.preview(base: Data("a\n".utf8), versions: [Data("b\n".utf8),Data("c\n".utf8)])
        checkTrue(overlap.hasConflicts); checkTrue(overlap.text.contains("<<<<<<<"))
        checkThrows(try TextMerge.preview(base: Data([0]), versions: [Data([0])]))
    }
    func testConcurrentIdenticalJoinsConvergeDeterministically() throws {
        let a = try node("a"), b = try node("b")
        try write(a, "same"); try write(b, "same"); _ = try a.scan(); _ = try b.scan()
        try exchange(a,b); try exchange(b,a)
        _ = try a.scan(); _ = try b.scan()
        let ah = ObjectStore.heads(path: "note.md", revisions: try a.store.load().revisions)
        let bh = ObjectStore.heads(path: "note.md", revisions: try b.store.load().revisions)
        checkEqual(ah.map(\.id),bh.map(\.id))
        try exchange(a,b); try exchange(b,a); _ = try a.scan(); _ = try b.scan()
        checkEqual(try a.store.load().revisions.count,3)
    }
    func testRemoteChangeInvalidatesOpenMerge() throws {
        let a = try node("a"), b = try node("b")
        try write(a,"a"); try write(b,"b"); _ = try a.scan(); _ = try b.scan(); try exchange(b,a)
        let conflict = try unwrap(a.scan().conflicts.first)
        try write(b,"new remote work"); _ = try b.scan(); try exchange(b,a)
        checkThrows(try a.resolve(path: "note.md", expectedHeads: conflict.heads.map(\.id), data: Data("obsolete".utf8)))
        checkEqual(try read(a),"a")
    }
    func testPathCaseAndFileDirectoryCollisionsAreHeld() throws {
        let a = try node("a")
        for path in ["Note.md","note.md","folder","folder/child.md"] {
            _ = try a.store.create(path: path, parents: [], data: Data(path.utf8), device: "remote")
        }
        let report = try a.scan()
        checkEqual(report.files,0); checkFalse(report.notices.isEmpty)
        checkFalse(FileManager.default.fileExists(atPath: a.mapping.path + "/Note.md"))
        checkFalse(FileManager.default.fileExists(atPath: a.mapping.path + "/folder"))
    }
    func testBinaryResolutionPreservesOtherVersion() throws {
        let a = try node("a")
        let left = Data([0,1,2]), right = Data([0,3,4])
        _ = try a.store.create(path:"image.bin",parents:[],data:left,device:"left")
        _ = try a.store.create(path:"image.bin",parents:[],data:right,device:"right")
        let conflict = try unwrap(a.scan().conflicts.first)
        checkTrue(conflict.base == nil)
        _ = try a.resolve(path:"image.bin",expectedHeads:conflict.heads.map(\.id),data:right)
        checkEqual(try Data(contentsOf: URL(fileURLWithPath:a.mapping.path + "/image.bin")),right)
        let history = try a.history(path:"image.bin")
        checkEqual(history.count,3)
        checkTrue(try history.contains { try a.content($0) == left })
    }
    func testMultiBranchPreviewNeverHidesAnUnprocessedBranch() throws {
        checkThrows(try TextMerge.preview(base:Data("a\n".utf8),versions:[Data("b\n".utf8),Data("c\n".utf8),Data("d\n".utf8)]))
        let base = "first\n\nmiddle\n\nlast\n"
        let clean = try TextMerge.preview(base:Data(base.utf8),versions:[Data(base.replacingOccurrences(of:"first",with:"FIRST").utf8),Data(base.replacingOccurrences(of:"middle",with:"MIDDLE").utf8),Data(base.replacingOccurrences(of:"last",with:"LAST").utf8)])
        checkFalse(clean.hasConflicts); checkEqual(clean.text,"FIRST\n\nMIDDLE\n\nLAST\n")
    }
    func testPeerValidationRestrictsTailnetAddresses() throws {
        checkTrue(Peer.isTailIP("100.64.0.1")); checkTrue(Peer.isTailIP("fd7a:115c:a1e0::1"))
        for bad in ["192.168.1.1","100.64.0.1.evil","100.63.0.1","100.128.0.1","fd7a:115c:a1e0:garbage","127.0.0.1"] { checkFalse(Peer.isTailIP(bad)) }
        checkThrows(try Peer(id:String(repeating:"A",count:56),name:"x",host:"example.com").validate())
    }
    func testRemappingSameVaultIDToNewFolderDoesNotPublishDeletion() throws {
        let a = try node("a"); try write(a,"keep"); _ = try a.scan()
        let newRoot = temp.appendingPathComponent("new-folder"); try FileManager.default.createDirectory(at:newRoot,withIntermediateDirectories:true)
        let newEngine = try VaultEngine(mapping:VaultMapping(id:vaultID,name:"remapped",path:newRoot.path),transportRoot:temp.appendingPathComponent("a/objects"),stateRoot:temp.appendingPathComponent("a/state"),device:"a")
        _ = try newEngine.scan()
        checkEqual(try read(newEngine),"keep"); checkEqual(try newEngine.store.load().revisions.count,1)
    }
    func testDeltaCaptureTracksFileAndDirectoryChanges() throws {
        let a = try node("a")
        try write(a, "original")
        try write(a, "nested", path: "old/folder/child.md")
        _ = try a.scan()
        try write(a, "changed")
        try write(a, "elsewhere", path: "unrelated.md")
        let edited = try a.scan(changes: ScanChanges(local: FileChanges(files: ["note.md"])))
        checkEqual(edited.revisions, 3)
        checkEqual(edited.files, 2)
        let original = URL(fileURLWithPath: a.mapping.path)
        try FileManager.default.moveItem(at: original.appendingPathComponent("old"),
                                         to: original.appendingPathComponent("new"))
        let moved = try a.scan(changes: ScanChanges(local: FileChanges(directories: ["old", "new"])))
        checkEqual(moved.revisions, 5)
        checkEqual(moved.files, 2)
        let loaded = try a.store.load(changes: FileChanges()).revisions
        checkTrue(ObjectStore.heads(path: "old/folder/child.md", revisions: loaded).allSatisfy { $0.payload.blob == nil })
        checkEqual(ObjectStore.heads(path: "new/folder/child.md", revisions: loaded).count, 1)
        let reconciled = try a.scan()
        checkEqual(reconciled.files, 3)
        checkEqual(reconciled.revisions, 6)
    }

    func testDeltaObjectDeliveryWaitsForVerifiedBlob() throws {
        let a = try node("a"), b = try node("b")
        _ = try b.scan()
        try write(a, "arrives later")
        _ = try a.scan()
        let revision = try unwrap(a.history(path: "note.md").first)
        let revisionPath = "revisions/" + revision.id + ".json"
        let blobPath = "blobs/" + (try unwrap(revision.payload.blob))
        func deliver(_ path: String) throws {
            try FileManager.default.copyItem(at: a.store.root.appendingPathComponent(path),
                                             to: b.store.root.appendingPathComponent(path))
        }
        try deliver(revisionPath)
        let waiting = try b.scan(changes: ScanChanges(objects: FileChanges(files: [revisionPath])))
        checkEqual(waiting.files, 0)
        checkEqual(waiting.revisions, 0)
        try deliver(blobPath)
        let complete = try b.scan(changes: ScanChanges(objects: FileChanges(files: [blobPath])))
        checkEqual(complete.revisions, 1)
        checkEqual(try read(b), "arrives later")
        try Data("corrupt".utf8).write(to: b.store.root.appendingPathComponent(blobPath))
        let corrupt = try b.scan(changes: ScanChanges(objects: FileChanges(files: [blobPath])))
        checkEqual(corrupt.revisions, 0)
        checkEqual(try read(b), "arrives later")
    }

    func testReplacedVaultDoesNotGenerateDeletions() throws {
        let a = try node("a")
        try write(a, "keep")
        _ = try a.scan()
        let root = URL(fileURLWithPath: a.mapping.path)
        try FileManager.default.moveItem(at: root, to: root.deletingLastPathComponent().appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        checkThrows(try a.scan(changes: ScanChanges(local: FileChanges(files: ["note.md"]))))
        let history = try a.history(path: "note.md")
        checkEqual(history.count, 1)
        checkTrue(history.first?.payload.blob != nil)
    }

    func testCaseOnlyRenameDoesNotResurrectOldPath() throws {
        let a = try node("a"), b = try node("b")
        try write(a,"content"); _ = try a.scan(); try exchange(a,b); _ = try b.scan()
        let old = a.mapping.path + "/note.md", temp = a.mapping.path + "/temporary.md", renamed = a.mapping.path + "/Note.md"
        try FileManager.default.moveItem(atPath:old,toPath:temp)
        try FileManager.default.moveItem(atPath:temp,toPath:renamed)
        let changes = ScanChanges(local: FileChanges(files: ["note.md", "Note.md", "temporary.md"]))
        checkTrue(try a.scan(changes: changes).notices.isEmpty)
        try exchange(a,b); _ = try b.scan(); _ = try b.scan()
        let actual = try FileManager.default.contentsOfDirectory(atPath:b.mapping.path)
        checkTrue(actual.contains("Note.md")); checkFalse(actual.contains("note.md"))
        checkTrue(try a.scan().notices.isEmpty); checkTrue(try b.scan().notices.isEmpty)
        let heads = ObjectStore.heads(path:"note.md",revisions:try b.store.load().revisions)
        checkTrue(heads.allSatisfy { $0.payload.blob == nil })
    }
}
