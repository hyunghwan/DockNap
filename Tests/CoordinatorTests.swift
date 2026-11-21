import Foundation

/// In-process tests. No real volumes, power notifications, or sleeps are used.
private final class Rig {
    var selected: Set<String>
    var mounted: [String: Bool]
    var unmountCalls = [String]()
    var mountCalls = [String]()
    var acknowledgements = 0
    var attachmentOverrides = [String: String]()
    var deferMounts = false
    var canMountVolumes = true
    var soundCompletions = [() -> Void]()
    private var pendingMounts = [String: (Bool) -> Void]()
    private var replies = [String: [(Bool) -> Void]]()
    private var scheduled = [(deadline: TimeInterval, action: () -> Void)]()
    private var now: TimeInterval = 0

    init(_ mounted: [String: Bool], selected: Set<String>) {
        self.mounted = mounted
        self.selected = selected
    }

    lazy var coordinator = SleepCoordinator(
        selected: { self.selected },
        mounted: { self.mounted[$0] },
        unmount: { id, reply in
            self.unmountCalls.append(id)
            self.replies[id, default: []].append(reply)
        },
        mount: { id, reply in
            self.mountCalls.append(id)
            self.pendingMounts[id] = reply
            if !self.deferMounts { self.finishMount(id) }
        },
        schedule: { delay, action in
            self.scheduled.append((self.now + delay, action))
        },
        attachment: { id in
            self.mounted[id] == nil ? nil : (self.attachmentOverrides[id] ?? id)
        },
        canMountVolumes: { self.canMountVolumes }
    )

    func sleep() {
        coordinator.willSleep { self.acknowledgements += 1 }
    }

    func observeSound(canSignal: Bool = true) {
        coordinator.canSignalSafeRemoval = { canSignal }
        coordinator.onReadyForSleep = { self.soundCompletions.append($0) }
    }

    func finishUnmount(_ id: String, success: Bool = true) {
        guard var callbacks = replies[id], !callbacks.isEmpty else {
            fatalError("Missing unmount request for \(id)")
        }
        let callback = callbacks.removeFirst()
        replies[id] = callbacks
        if success, mounted[id] != nil { mounted[id] = false }
        callback(success)
    }

    func finishMount(_ id: String) {
        guard let reply = pendingMounts.removeValue(forKey: id) else {
            fatalError("Missing mount request for \(id)")
        }
        let present = mounted[id] != nil
        if present { mounted[id] = true }
        reply(present)
    }

    func runNextTimer() -> Bool {
        guard let i = scheduled.indices.min(by: {
            scheduled[$0].deadline < scheduled[$1].deadline
        }) else { return false }
        let timer = scheduled.remove(at: i)
        now = timer.deadline
        timer.action()
        return true
    }

    func runTimers() {
        for _ in 0..<100 {
            if !runNextTimer() { return }
        }
        fatalError("Timer queue did not settle")
    }

    func removeSelection(_ id: String) {
        selected.remove(id)
        coordinator.selectionRemoved(id)
    }

    func disconnect(_ id: String) {
        mounted.removeValue(forKey: id)
        coordinator.volumeDisconnected(id)
    }
}

@main
private enum CoordinatorTests {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                              line: UInt = #line) {
        guard condition() else { fatalError("Line \(line): \(message)") }
    }

    static func main() {
        selectedVolumesAndBusyDisk()
        disconnectedAndDeselectedVolumes()
        wakeBeforeUnmountReply()
        rapidSleepWakeSleep()
        noSelectionAndNoPriorSleep()
        attachmentReplacedWhileAsleep()
        mountReplyAfterNextSleep()
        lockedWakeWaitsForUnlock()
        sleepingAgainWhileWaitingForUnlock()
        sleepWaitsForUnmountSound()
        incompleteUnmountsStaySilent()
        noWorkOrUnsafeInventoryStaysSilent()
        expiredSleepStaysSilent()
        wakeBeforeSoundStaysSilent()
        staleSoundCannotAllowAnotherSleep()
        print("15 coordinator scenarios passed")
    }

    /// Busy, absent, already-unmounted and unselected volumes must never be mounted by this cycle.
    static func selectedVolumesAndBusyDisk() {
        let rig = Rig(["A": true, "B": true, "busy": true, "manual": false, "other": true],
                      selected: ["A", "B", "busy", "manual", "absent"])
        rig.sleep()
        check(rig.unmountCalls.sorted() == ["A", "B", "busy"], "Incorrect selection on sleep")
        rig.finishUnmount("B")
        rig.finishUnmount("busy", success: false)
        check(rig.acknowledgements == 0, "Sleep was acknowledged before the last reply")
        rig.finishUnmount("A")
        check(rig.acknowledgements == 1 && rig.mountCalls.isEmpty, "Unexpected sleep completion")

        rig.coordinator.didWake()
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls.sorted() == ["A", "B"], "Wake must restore only its two successful unmounts")
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls.count == 2, "A repeat wake must not remount twice")
    }

    static func disconnectedAndDeselectedVolumes() {
        let candidates = ["keep", "removed", "gone", "lateRemoved", "lateGone", "alreadyBack"]
        let rig = Rig(Dictionary(uniqueKeysWithValues: candidates.map { ($0, true) }),
                      selected: Set(candidates))
        rig.sleep()
        for id in ["removed", "gone", "keep", "alreadyBack"] { rig.finishUnmount(id) }
        for id in ["removed", "lateRemoved"] {
            rig.removeSelection(id)
            rig.selected.insert(id)
        }
        for id in ["gone", "lateGone"] {
            rig.disconnect(id)
            rig.mounted[id] = false
        }
        rig.finishUnmount("lateRemoved")
        rig.finishUnmount("lateGone")
        rig.mounted["alreadyBack"] = true // macOS or the user already mounted it.
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls == ["keep"], "Detach or deselect must revoke an old restore, including late replies")
    }

    static func wakeBeforeUnmountReply() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.sleep()
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls.isEmpty, "Pending unmount cannot be considered safe to restore")
        rig.finishUnmount("A")
        rig.runTimers()
        check(rig.mountCalls == ["A"] && rig.acknowledgements == 1,
              "A late successful unmount must restore its volume once if already awake")
    }

    static func rapidSleepWakeSleep() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.sleep()
        rig.finishUnmount("A")
        rig.coordinator.didWake()
        // When restore is deferred, a second sleep can arrive before it fires.
        if rig.mountCalls.isEmpty {
            rig.sleep()
            rig.runTimers()
            check(rig.mountCalls.isEmpty, "A stale wake timer mounted while asleep")
            rig.coordinator.didWake()
            rig.runTimers()
            check(rig.mountCalls == ["A"], "The second wake lost ownership of a pending restore")
        } else {
            rig.sleep()
            rig.finishUnmount("A")
            rig.coordinator.didWake()
            rig.runTimers()
            check(rig.mountCalls == ["A","A"], "Expected one restore in each completed cycle")
        }
        check(rig.acknowledgements == 2, "Each sleep must get one reply")
    }

    static func attachmentReplacedWhileAsleep() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.attachmentOverrides["A"] = "attachment-one"
        rig.sleep()
        rig.finishUnmount("A")
        rig.attachmentOverrides["A"] = "attachment-two"
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls.isEmpty, "An identically named UUID on a new attachment cannot inherit a restore")
    }

    static func mountReplyAfterNextSleep() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.deferMounts = true
        rig.sleep()
        rig.finishUnmount("A")
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls == ["A"], "Expected the first wake to request a mount")
        rig.sleep()
        check(rig.acknowledgements == 1, "Second sleep acknowledged before pending mount settled")
        rig.finishMount("A")
        check(rig.unmountCalls == ["A", "A"], "A mount completed during a new sleep without re-unmount")
        rig.finishUnmount("A")
        check(rig.acknowledgements == 2, "Re-unmount should complete the second sleep")
        rig.coordinator.didWake()
        rig.runTimers()
        rig.finishMount("A")
        check(rig.mounted["A"] == true && rig.mountCalls.count == 2, "Expected the second wake to restore the disk")
    }

    static func noSelectionAndNoPriorSleep() {
        let rig = Rig(["A": true, "B": false], selected: [])
        rig.coordinator.didWake()
        rig.runTimers()
        rig.sleep()
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.unmountCalls.isEmpty && rig.mountCalls.isEmpty && rig.acknowledgements == 1,
              "Empty selection or unrelated wake must leave all volumes alone")
    }

    static func lockedWakeWaitsForUnlock() {
        let selected: Set<String> = ["keep", "deselected", "disconnected", "replaced"]
        let rig = Rig(Dictionary(uniqueKeysWithValues: selected.map { ($0, true) }), selected: selected)
        rig.sleep()
        for id in selected { rig.finishUnmount(id) }

        rig.canMountVolumes = false
        rig.coordinator.didWake()
        for _ in 0..<3 {
            check(rig.runNextTimer(), "A locked wake lost its pending restore")
            check(rig.mountCalls.isEmpty, "A mount request reached the lock screen")
        }
        rig.removeSelection("deselected")
        rig.disconnect("disconnected")
        rig.attachmentOverrides["replaced"] = "replacement"

        rig.canMountVolumes = true
        check(rig.runNextTimer() && rig.mountCalls.isEmpty, "Give the login screen time to release disk approvals")
        rig.canMountVolumes = false
        check(rig.runNextTimer() && rig.mountCalls.isEmpty, "The session locked again before the mount")
        rig.canMountVolumes = true
        rig.runTimers()
        check(rig.mountCalls == ["keep"], "Unlock should only restore the still-selected original attachment")
        check(rig.mounted["keep"] == true, "The deferred mount did not complete")
    }

    static func sleepingAgainWhileWaitingForUnlock() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.sleep()
        rig.finishUnmount("A")
        rig.canMountVolumes = false
        rig.coordinator.didWake()
        check(rig.runNextTimer() && rig.mountCalls.isEmpty, "Expected restore to wait at the lock screen")

        rig.sleep()
        rig.canMountVolumes = true
        rig.runTimers()
        check(rig.mountCalls.isEmpty, "A pending lock check mounted the disk during the next sleep")
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls == ["A"] && rig.acknowledgements == 2, "The next wake must restore exactly once")
    }

    static func sleepWaitsForUnmountSound() {
        let rig = Rig(["A": true, "B": true], selected: ["A", "B"])
        rig.observeSound()
        rig.sleep()
        rig.finishUnmount("B")
        check(rig.soundCompletions.isEmpty && rig.acknowledgements == 0, "One volume is still unmounting")
        rig.finishUnmount("A")
        check(rig.soundCompletions.count == 1 && rig.acknowledgements == 0, "Sleep must wait for the one success cue")
        rig.soundCompletions[0]()
        rig.soundCompletions[0]()
        check(rig.acknowledgements == 1 && rig.soundCompletions.count == 1, "Completing the sound must allow sleep once")
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls.sorted() == ["A", "B"] && rig.soundCompletions.count == 1, "Wake must restore silently")
    }

    static func incompleteUnmountsStaySilent() {
        let busy = Rig(["A": true, "busy": true], selected: ["A", "busy"])
        busy.observeSound()
        busy.sleep()
        busy.finishUnmount("busy", success: false)
        busy.finishUnmount("A")
        check(busy.soundCompletions.isEmpty && busy.acknowledgements == 1, "A partial success must stay silent")

        let unplugged = Rig(["A": true, "B": true], selected: ["A", "B"])
        unplugged.observeSound()
        unplugged.sleep()
        unplugged.disconnect("B")
        unplugged.finishUnmount("B")
        unplugged.finishUnmount("A")
        check(unplugged.soundCompletions.isEmpty && unplugged.acknowledgements == 1, "A detached target did not finish safely")
    }

    static func noWorkOrUnsafeInventoryStaysSilent() {
        let idle = Rig(["manual": false], selected: ["manual", "absent"])
        idle.observeSound()
        idle.sleep()
        check(idle.soundCompletions.isEmpty && idle.acknowledgements == 1, "No unmount means no completion sound")

        let blocked = Rig(["A": true, "other": true], selected: ["A"])
        blocked.observeSound(canSignal: false)
        blocked.sleep()
        blocked.finishUnmount("A")
        check(blocked.soundCompletions.isEmpty && blocked.acknowledgements == 1, "Unsafe inventory must suppress the cue")
        check(blocked.unmountCalls == ["A"], "The readiness check must leave unselected volumes alone")
    }

    static func expiredSleepStaysSilent() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.observeSound()
        rig.sleep()
        rig.coordinator.canSignalSafeRemoval = { false } // The power monitor's playback window expired.
        rig.finishUnmount("A")
        check(rig.soundCompletions.isEmpty, "A late success must not signal after the sleep deadline")
        rig.coordinator.didWake()
        rig.runTimers()
        check(rig.mountCalls == ["A"], "A missed cue must not lose the restore")
        rig.coordinator.canSignalSafeRemoval = { true }
        rig.sleep()
        rig.finishUnmount("A")
        check(rig.soundCompletions.count == 1, "The next sleep should signal normally")
        rig.soundCompletions[0]()
    }

    static func wakeBeforeSoundStaysSilent() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.observeSound()
        rig.sleep()
        rig.coordinator.didWake()
        rig.finishUnmount("A")
        rig.runTimers()
        check(rig.soundCompletions.isEmpty && rig.mountCalls == ["A"], "A late unmount must restore without playing on wake")
    }

    static func staleSoundCannotAllowAnotherSleep() {
        let rig = Rig(["A": true], selected: ["A"])
        rig.observeSound()
        rig.sleep()
        rig.finishUnmount("A")
        check(rig.soundCompletions.count == 1, "The first cue should be in flight")
        rig.coordinator.didWake()
        rig.runTimers()
        var latestAcknowledgements = 0
        rig.coordinator.willSleep { latestAcknowledgements += 1 }
        rig.finishUnmount("A")
        check(rig.soundCompletions.count == 2, "An old sound must not suppress the next sleep's cue")
        rig.soundCompletions[0]()
        check(latestAcknowledgements == 0, "An old sound released the current sleep")
        rig.soundCompletions[1]()
        check(latestAcknowledgements == 1, "The current cue should release the current sleep once")
    }
}
