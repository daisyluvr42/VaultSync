import Foundation
import VaultWeaveCore

extension EngineTests {
    private func cliFixture(_ name: String, script: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func testFinderLaunchForcesTailscaleCLIMode() throws {
        let cli = try cliFixture("Tailscale", script: """
        if [ "$TAILSCALE_BE_CLI" != "1" ]; then
          printf '%s' 'The Tailscale GUI failed to start: Tailscale.CLIError error 3.'
          exit 0
        fi
        printf '%s' '{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.8"]}}'
        """)
        // Match Finder's environment, with no SHLVL, TERM, TERM_PROGRAM or PS1.
        checkEqual(try SyncthingService.tailscaleAddress(candidates: [cli], environment: [:]), "100.64.0.8")
        checkEqual(try SyncthingService.tailscaleAddress(candidates: [cli], environment: ["TAILSCALE_BE_CLI":"0"]), "100.64.0.8")
    }
    func testTailscaleCandidateFallbackAndActionableErrors() throws {
        let broken = try cliFixture("stale-launcher", script: "printf '%s' 'The Tailscale GUI failed to start'; exit 0")
        let good = try cliFixture("app-binary", script: "printf '%s' '{\"BackendState\":\"Running\",\"TailscaleIPs\":[\"100.64.0.9\"]}'")
        checkEqual(try SyncthingService.tailscaleAddress(candidates: [broken,good], environment: [:]), "100.64.0.9")
        do {
            _ = try SyncthingService.tailscaleAddress(candidates: [broken], environment: [:])
            checkTrue(false)
        } catch {
            checkTrue(error.localizedDescription.contains("Tailscale"))
            checkTrue(error.localizedDescription.contains("JSON"))
            checkFalse(error.localizedDescription.contains("The data couldn"))
        }
    }
    func testTailscaleStatusParsingRejectsInvalidAndOfflineResults() throws {
        for invalid in ["", "The Tailscale GUI failed to start", "[]", "{}", "{\"BackendState\":\"Stopped\"}", "{\"BackendState\":\"Running\",\"TailscaleIPs\":[\"192.168.0.1\"]}"] {
            checkThrows(try SyncthingService.parseTailscaleStatus(Data(invalid.utf8)))
        }
        let fallback = Data("{\"BackendState\":\"Running\",\"Self\":{\"TailscaleIPs\":[]},\"TailscaleIPs\":[\"100.100.1.1\"]}".utf8)
        checkEqual(try SyncthingService.parseTailscaleStatus(fallback), "100.100.1.1")
    }
}
