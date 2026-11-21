import AVFAudio
import Foundation

final class UnmountSound: NSObject, AVAudioPlayerDelegate {
    private var activePlayer: AVAudioPlayer?
    private var completions = [() -> Void]()

    func play(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        if activePlayer != nil {
            completions.append(completion)
            return
        }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            completion()
            return
        }
        activePlayer = player
        completions.append(completion)
        player.delegate = self
        guard player.play() else {
            finish(player)
            return
        }
        // An unavailable audio output must not hold the sleep acknowledgement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.finish(player)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.finish(player) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { self.finish(player) }
    }

    private func finish(_ player: AVAudioPlayer) {
        guard activePlayer === player else { return }
        activePlayer = nil
        player.delegate = nil
        player.stop()
        let replies = completions
        completions.removeAll()
        replies.forEach { $0() }
    }
}
