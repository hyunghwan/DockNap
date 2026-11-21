import Foundation

/// All events and disk callbacks are delivered on the main thread.
final class SleepCoordinator {
    typealias Reply = (Bool) -> Void
    typealias Operation = (String, @escaping Reply) -> Void

    private let selected: () -> Set<String>
    private let mounted: (String) -> Bool?
    private let attachment: (String) -> String?
    private let canMountVolumes: () -> Bool
    private let unmount: Operation
    private let mount: Operation
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    var onFailure: ((String, String) -> Void)?
    var canSignalSafeRemoval: () -> Bool = { false }
    var onReadyForSleep: ((@escaping () -> Void) -> Void)?

    private var awake = true
    private var wakeGeneration = 0
    private var wakeTimerPending = false
    private var waitingForUnlock = false
    private var didUnmountThisSleep = false
    private var allUnmountsSucceeded = true
    private var unmounting = [String: UUID]()
    private var mounting = [String: UUID]()
    // Only successful unmounts earn a restore. Record the live attachment as
    // well as the persistent selection so a replacement disk cannot inherit it.
    private var restore = [String: String]()
    private var sleepReplies = [() -> Void]()

    init(selected: @escaping () -> Set<String>, mounted: @escaping (String) -> Bool?,
         unmount: @escaping Operation, mount: @escaping Operation,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         attachment: @escaping (String) -> String?,
         canMountVolumes: @escaping () -> Bool) {
        self.selected = selected
        self.mounted = mounted
        self.unmount = unmount
        self.mount = mount
        self.schedule = schedule
        self.attachment = attachment
        self.canMountVolumes = canMountVolumes
    }

    func willSleep(allow: @escaping () -> Void) {
        awake = false
        wakeGeneration += 1
        wakeTimerPending = false
        waitingForUnlock = false
        didUnmountThisSleep = false
        allUnmountsSucceeded = true
        sleepReplies.append(allow)
        unmountVolumes(selected())
        acknowledgeIfIdle()
    }

    private func unmountVolumes(_ ids: Set<String>) {
        let cycle = wakeGeneration
        // Reserve every request before dispatching: callbacks may be synchronous.
        let work: [(String, String, UUID)] = ids.sorted().compactMap { id in
            guard unmounting[id] == nil, mounting[id] == nil, mounted(id) == true,
                  let connection = attachment(id) else { return nil }
            let ticket = UUID()
            unmounting[id] = ticket
            return (id, connection, ticket)
        }
        for (id, connection, ticket) in work {
            unmount(id) { [weak self] ok in
                guard let self, self.unmounting[id] == ticket else { return }
                self.unmounting.removeValue(forKey: id)
                if self.attachment(id) == connection && self.selected().contains(id) {
                    if ok {
                        self.restore[id] = connection
                        if self.wakeGeneration == cycle { self.didUnmountThisSleep = true }
                        self.scheduleRestore()
                    } else {
                        self.allUnmountsSucceeded = false
                        self.onFailure?(id, "unmount")
                    }
                } else {
                    self.allUnmountsSucceeded = false
                }
                self.acknowledgeIfIdle()
            }
        }
    }

    func didWake() {
        awake = true
        scheduleRestore()
    }

    func selectionRemoved(_ id: String) { forget(id) }
    func volumeDisconnected(_ id: String) { forget(id) }

    private func forget(_ id: String) {
        if unmounting[id] != nil || restore[id] != nil { allUnmountsSucceeded = false }
        restore.removeValue(forKey: id)
        unmounting.removeValue(forKey: id)
        mounting.removeValue(forKey: id)
        acknowledgeIfIdle()
    }

    private func acknowledgeIfIdle() {
        guard !sleepReplies.isEmpty, unmounting.isEmpty, mounting.isEmpty else { return }
        var replies = sleepReplies
        sleepReplies.removeAll()
        // The completion belongs to this sleep, even if playback ends after a wake.
        let allow = {
            let pending = replies
            replies.removeAll()
            pending.forEach { $0() }
        }
        if !awake, didUnmountThisSleep, allUnmountsSucceeded, let onReadyForSleep, canSignalSafeRemoval() {
            onReadyForSleep(allow)
        } else {
            allow()
        }
    }

    private func scheduleRestore(after delay: TimeInterval = 1.5) {
        guard awake, !restore.isEmpty, !wakeTimerPending else { return }
        wakeTimerPending = true
        let generation = wakeGeneration
        schedule(delay) { [weak self] in
            guard let self, self.awake, self.wakeGeneration == generation else { return }
            self.wakeTimerPending = false
            guard !self.restore.isEmpty else { return }
            // loginwindow can eject the entire device if asked to mount it at the lock screen.
            guard self.canMountVolumes() else {
                self.waitingForUnlock = true
                self.scheduleRestore(after: 5)
                return
            }
            if self.waitingForUnlock {
                self.waitingForUnlock = false
                // Allow loginwindow to finish unregistering its disk approval callbacks.
                self.scheduleRestore()
                return
            }
            self.restoreConnectedVolumes()
        }
    }

    private func restoreConnectedVolumes() {
        let candidates = restore
        restore.removeAll()
        for (id, connection) in candidates {
            guard selected().contains(id), attachment(id) == connection,
                  mounted(id) == false else { continue }
            let ticket = UUID()
            mounting[id] = ticket
            mount(id) { [weak self] ok in
                guard let self, self.mounting[id] == ticket else { return }
                self.mounting.removeValue(forKey: id)
                if !ok {
                    self.onFailure?(id, "mount")
                } else if !self.awake, self.selected().contains(id), self.attachment(id) == connection {
                    // The next sleep arrived while this mount was in flight.
                    self.unmountVolumes([id])
                }
                self.acknowledgeIfIdle()
            }
        }
    }
}
