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
        }
    )

    func sleep() {
        coordinator.willSleep { self.acknowledgements += 1 }
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

    func runTimers() {
        for _ in 0..<100 {
            guard let i = scheduled.indices.min(by: {
                scheduled[$0].deadline < scheduled[$1].deadline
            }) else { return }
            let timer = scheduled.remove(at: i)
            now = timer.deadline
            timer.action()
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
        print("7 coordinator scenarios passed")
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
}
