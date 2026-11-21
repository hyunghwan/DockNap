import AVFAudio
import Darwin
import Foundation
import OSLog

private let audioLog = Logger(subsystem: "com.sqncsstudio.DockNap", category: "UnmountSound")

final class UnmountSound {
    static let helperArgument = "--play-unmount-sound"
    static let timeout: TimeInterval = 2
    private let helperURL: URL?
    private let timeout: TimeInterval
    private var helper: Process?
    private var completions = [() -> Void]()

    init(helperURL: URL? = Bundle.main.executableURL, timeout: TimeInterval = UnmountSound.timeout) {
        self.helperURL = helperURL
        self.timeout = timeout
    }

    func play(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard let helperURL else { completion(); return }
        completions.append(completion)
        guard helper == nil else { return }

        // CoreAudio can block inside play() while a display powers down.
        // Isolate that call so a stuck output cannot stall IOKit or play after wake.
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [Self.helperArgument]
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.finish(ended) }
        }
        helper = process
        let deadline = DispatchTime.now() + timeout
        do {
            try process.run()
        } catch {
            audioLog.error("Could not launch the unmount sound")
            finish(process)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.helper === process else { return }
            if process.isRunning {
                audioLog.notice("Audio output missed the sleep deadline")
                self.cancel()
            } else {
                self.finish(process)
            }
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard let helper else { return }
        if helper.isRunning { kill(helper.processIdentifier, SIGKILL) }
        finish(helper)
    }

    private func finish(_ process: Process) {
        guard helper === process else { return }
        helper = nil
        let replies = completions
        completions.removeAll()
        replies.forEach { $0() }
    }
}

// Runs only in the short-lived audio process. The parent owns its time limit.
final class ChimePlayback: NSObject, AVAudioPlayerDelegate {
    private var result: Bool?

    func run() -> Bool {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        guard let speaker = ChimeOutput.builtInSpeakerUID() else {
            audioLog.notice("Built-in speaker unavailable for unmount sound")
            return false
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.currentDevice = speaker
        guard player.currentDevice == speaker else {
            audioLog.error("Could not select built-in speaker")
            return false
        }
        audioLog.notice("Routing unmount sound to built-in speaker")
        player.delegate = self
        guard player.play() else { return false }
        return withExtendedLifetime(player) {
            while result == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025)) }
            if result == true { audioLog.notice("Completed unmount sound playback") }
            return result == true
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { result = flag }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { result = false }
}
