import Foundation
import Darwin

// A tiny dependency-free runner, usable with Apple's Command Line Tools (no XCTest installation).
private var failures: [String] = []
class CheckSuite {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func checkEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                             file: String = #fileID, line: Int = #line) {
    do { let a = try lhs(), b = try rhs(); if a != b { failures.append("\(file):\(line): \(a) != \(b)") } }
    catch { failures.append("\(file):\(line): \(error)") }
}
func checkTrue(_ value: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) {
    do { if try !value() { failures.append("\(file):\(line): expected true") } } catch { failures.append("\(file):\(line): \(error)") }
}
func checkFalse(_ value: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) {
    do { if try value() { failures.append("\(file):\(line): expected false") } } catch { failures.append("\(file):\(line): \(error)") }
}
func checkThrows<T>(_ value: @autoclosure () throws -> T, file: String = #fileID, line: Int = #line) {
    do { _ = try value(); failures.append("\(file):\(line): expected an error") } catch {}
}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Checks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing expected value"]) }
    return value
}

@main struct CheckRunner {
    static func main() {
        setbuf(stdout, nil)
        let tests = EngineTests()
        let cases: [(String, () throws -> Void)] = [
            ("initial sync + attachments", tests.testInitialSyncAndNestedAttachments),
            ("offline branches + explicit merge", tests.testOfflineBranchesRetainBaseAndRequireExplicitMerge),
            ("four nodes + late offline branch", tests.testFourNodesAndLateOfflineBranch),
            ("stale merge protects local work", tests.testLocalEditInvalidatesOpenMerge),
            ("delete vs edit + delete propagation", tests.testDeleteVsEditAndDeletePropagation),
            ("identical import coalesces", tests.testIdenticalIndependentlyImportedContentCoalesces),
            ("restart retains ancestry", tests.testRestartRetainsAncestry),
            ("history restore creates revision", tests.testHistoryRestoreCreatesNewRevision),
            ("unavailable vault is not deletion", tests.testMissingVaultDoesNotBecomeMassDeletion),
            ("out-of-order transport", tests.testMissingParentAndBlobDoNotApplyPartialVersion),
            ("path + symlink + hash integrity", tests.testPathTraversalSymlinkAndTamperedObjectRejected),
            ("workspace exclusions", tests.testWorkspaceAndGitIgnored),
            ("three-way text merge", tests.testCleanThreeWayMergeAndOverlappingConflict),
            ("deterministic identical joins", tests.testConcurrentIdenticalJoinsConvergeDeterministically),
            ("remote change invalidates merge", tests.testRemoteChangeInvalidatesOpenMerge),
            ("case + file-directory collisions", tests.testPathCaseAndFileDirectoryCollisionsAreHeld),
            ("binary conflict preserves originals", tests.testBinaryResolutionPreservesOtherVersion),
            ("multi-branch preview completeness", tests.testMultiBranchPreviewNeverHidesAnUnprocessedBranch),
            ("Tailnet address validation", tests.testPeerValidationRestrictsTailnetAddresses),
            ("remapping is not deletion", tests.testRemappingSameVaultIDToNewFolderDoesNotPublishDeletion),
            ("case-only rename", tests.testCaseOnlyRenameDoesNotResurrectOldPath),
            ("incremental file and subtree scope", tests.testDeltaCaptureTracksFileAndDirectoryChanges),
            ("incremental late and corrupted content object", tests.testDeltaObjectDeliveryWaitsForVerifiedBlob),
            ("replaced vault cannot publish deletions", tests.testReplacedVaultDoesNotGenerateDeletions),
            ("Finder launch forces Tailscale CLI", tests.testFinderLaunchForcesTailscaleCLIMode),
            ("Tailscale fallback + actionable error", tests.testTailscaleCandidateFallbackAndActionableErrors),
            ("Tailscale status shape + offline", tests.testTailscaleStatusParsingRejectsInvalidAndOfflineResults),
            ("pairing text formats + inline errors", tests.testPairingTextFormatsAndClearError),
            ("online Tailnet discovery filtering", tests.testTailnetDiscoveryOnlyUsesOnlinePrivatePeers),
            ("pairing approval + token checks", tests.testPairingWaitsForApprovalAndAuthenticatesRequest),
            ("pairing reject + cancel", tests.testPairingRejectAndCancel),
            ("cancelled scan preserves local and remote work", tests.testCancelledScanPreservesLocalAndRemoteWork),
            ("transfer progress includes pending metadata", tests.testTransferStatusSeparatesReceivingAndComplete),
            ("ignored files cannot hide siblings or create deletions", tests.testIgnoredFilesNeverHideSiblingsOrPublishDeletions)]
        for (name, test) in cases {
            let before = failures.count
            do { try tests.setUpWithError(); try test() } catch { failures.append("\(name): \(error)") }
            do { try tests.tearDownWithError() } catch { failures.append("cleanup: \(error)") }
            print("\(failures.count == before ? "PASS" : "FAIL") \(name)")
            for failure in failures.dropFirst(before) { print(failure) }
        }
        for failure in failures { print(failure) }
        print("\(cases.count) scenarios, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
