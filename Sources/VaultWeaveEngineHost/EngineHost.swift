import Foundation
import Darwin

/// Keeps the engine tied to its owning GUI/CLI, including SIGABRT and SIGKILL.
/// Dispatch process-exit notifications survive the owner's crash; no GUI deinit is required.
@main struct EngineHost {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 7, args[0] == "--parent", let owner = Int32(args[1]), owner > 1,
              args[2] == "--engine", args[4] == "--record", args[6] == "--", getppid() == owner else { exit(64) }
        let record = URL(fileURLWithPath: args[5])
        let queue = DispatchQueue(label: "app.vaultweave.engine-host")
        let child = Process(); child.executableURL = URL(fileURLWithPath: args[3]); child.arguments = Array(args.dropFirst(7))
        var environment = ProcessInfo.processInfo.environment
        environment["STMONITORED"] = "yes" // Run one worker; this process owns lifecycle supervision.
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
        var stopping = false
        func stop() {
            guard !stopping else { return }; stopping = true
            if child.isRunning {
                child.terminate()
                queue.asyncAfter(deadline: .now() + 20) { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) } }
            } else { exit(0) }
        }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN)
        let ownerExit = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: queue)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: queue)
        ownerExit.setEventHandler { stop() }; term.setEventHandler { stop() }; interrupt.setEventHandler { stop() }; hangup.setEventHandler { stop() }
        child.terminationHandler = { process in
            queue.async {
                if let data = try? Data(contentsOf: record), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Int], value["hostPID"] == Int(getpid()) { try? FileManager.default.removeItem(at: record) }
                exit(process.terminationStatus)
            }
        }
        ownerExit.resume(); term.resume(); interrupt.resume(); hangup.resume()
        queue.sync {
            guard getppid() == owner, kill(owner, 0) == 0 else { exit(0) }
            do {
                try child.run()
                let data = try JSONSerialization.data(withJSONObject: ["ownerPID":Int(owner),"hostPID":Int(getpid()),"enginePID":Int(child.processIdentifier)])
                try data.write(to: record, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            } catch {
                FileHandle.standardError.write(Data(("Engine host startup failed: " + error.localizedDescription + "\n").utf8))
                stop()
            }
        }
        // Retain the dispatch sources for the lifetime of the host.
        withExtendedLifetime([ownerExit as AnyObject, term as AnyObject, interrupt as AnyObject, hangup as AnyObject]) { dispatchMain() }
    }
}
