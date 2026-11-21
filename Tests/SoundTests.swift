import Darwin
import Foundation

@main
private enum SoundTests {
    struct Failure: Error { let message: String }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func wait(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    static func main() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("DockNapSoundTests-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        let log = directory.appendingPathComponent("calls")
        func installHelper(_ actions: String) throws {
            let script = """
            #!/bin/sh
            printf '%s %s\\n' "$$" "$1" >> "$(dirname "$0")/calls"
            \(actions)
            """
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        func calls() -> [[Substring]] {
            let contents = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return contents.split(separator: "\n").map { $0.split(separator: " ") }
        }

        try installHelper("exit 0")
        let normal = UnmountSound(helperURL: helper, timeout: 2)
        var completions = 0
        normal.play { completions += 1 }
        try check(wait(until: { completions == 1 }), "Successful helper failed to finish")
        try check(calls().count == 1 && calls()[0].last == "--play-unmount-sound", "Wrong helper invocation")
        normal.cancel()
        try check(completions == 1, "A finished helper completed again")

        let missing = UnmountSound(helperURL: directory.appendingPathComponent("missing"), timeout: 2)
        var skipped = 0
        missing.play { skipped += 1 }
        try check(wait(until: { skipped == 1 }, timeout: 0.5), "Missing helper held up sleep")

        // Ignore TERM so the test also catches a stranded audio process after the watchdog.
        try installHelper("trap '' TERM\nexec /bin/sleep 5")
        let stuck = UnmountSound(helperURL: helper, timeout: 0.4)
        var observedMainWhilePlaying = false
        var first = 0
        var second = 0
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            observedMainWhilePlaying = first == 0 && second == 0 && ProcessInfo.processInfo.systemUptime - start < 0.4
        }
        stuck.play { first += 1 }
        stuck.play { second += 1 }
        try check(wait(until: { first == 1 && second == 1 }), "Hung audio stalled sleep or lost a completion")
        try check(observedMainWhilePlaying, "Playback stalled the main run loop")
        try check(calls().count == 2, "Overlapping requests launched duplicate audio")
        guard let pidText = calls().last?.first, let stuckPID = Int32(pidText) else {
            throw Failure(message: "Missing helper PID")
        }
        try check(wait(until: { kill(stuckPID, 0) == -1 && errno == ESRCH }), "Timed-out helper survived")

        let cancelled = UnmountSound(helperURL: helper, timeout: 2)
        var cancelledCount = 0
        var nextCount = 0
        cancelled.play { cancelledCount += 1 }
        try check(wait(until: { calls().count == 3 }), "First helper failed to start")
        cancelled.cancel()
        cancelled.play { nextCount += 1 }
        try check(wait(until: { calls().count == 4 }), "Next helper failed to start")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        try check(cancelledCount == 1 && nextCount == 0, "A stale callback finished a newer helper")
        cancelled.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        try check(cancelledCount == 1 && nextCount == 1, "Cancellation must complete each caller once")
        print("4 sound helper scenarios passed")
    }
}
