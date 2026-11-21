import Foundation
import IOKit.pwr_mgt

// The iokit_common_msg macros from <IOKit/IOMessage.h> are not imported into Swift.
private enum SystemPowerMessage: UInt32 {
    case canSleep = 0xe0000270
    case willSleep = 0xe0000280
    case willNotSleep = 0xe0000290
    case hasPoweredOn = 0xe0000300
}

// Registration, delivery, and all state mutation belong to the main run loop.
// Only the completion passed to onWillSleep may be called from another queue.
final class PowerMonitor: @unchecked Sendable {
    private let onWillSleep: (@escaping () -> Void) -> Void
    private let onDidWake: () -> Void
    private var connection: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var sleepCycle: UInt64 = 0
    private var pending = Set<Int>()
    private var acknowledged = Set<Int>()
    private var preparing = false
    private var prepared = false

    init(onWillSleep: @escaping (@escaping () -> Void) -> Void, onDidWake: @escaping () -> Void) {
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread)
        if connection != 0 { return true }
        connection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &notificationPort,
            { context, _, message, argument in
                guard let context else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(message, token: Int(bitPattern: argument))
            }, &notifier
        )
        guard connection != 0, let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue()
        else {
            stop()
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        finish(cycle: sleepCycle)
        resetCycle()
        if let port = notificationPort, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    deinit {
        if connection != 0 { stop() }
    }

    private func receive(_ value: UInt32, token: Int) {
        guard connection != 0, let message = SystemPowerMessage(rawValue: value) else { return }
        switch message {
        case .canSleep:
            // An idle-sleep proposal can still be cancelled by other apps.
            IOAllowPowerChange(connection, token)
        case .willSleep:
            if acknowledged.contains(token) { return }
            pending.insert(token)
            if prepared {
                finish(cycle: sleepCycle)
                return
            }
            guard !preparing else { return }
            preparing = true
            let cycle = sleepCycle
            // Bound our own delay even if a disk is busy or has stopped responding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finish(cycle: cycle)
            }
            onWillSleep { [weak self] in
                DispatchQueue.main.async { self?.finish(cycle: cycle) }
            }
        case .willNotSleep:
            let started = preparing || prepared
            finish(cycle: sleepCycle)
            resetCycle()
            if started { onDidWake() }
        case .hasPoweredOn:
            finish(cycle: sleepCycle)
            resetCycle()
            onDidWake()
        }
    }

    private func finish(cycle: UInt64) {
        guard cycle == sleepCycle, !pending.isEmpty, connection != 0 else { return }
        for token in pending {
            IOAllowPowerChange(connection, token)
        }
        acknowledged.formUnion(pending)
        pending.removeAll()
        preparing = false
        prepared = true
    }

    private func resetCycle() {
        sleepCycle &+= 1
        pending.removeAll()
        acknowledged.removeAll()
        preparing = false
        prepared = false
    }
}
