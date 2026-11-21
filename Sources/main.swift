import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let disks = DiskService()
    private let unmountSound = UnmountSound()
    private let menu = NSMenu()
    private let defaultsKey = "selectedVolumes"
    private let soundKey = "playUnmountSound"
    private var selected = [String: String]()
    private var statusItem: NSStatusItem?
    private var power: PowerMonitor?
    private var startupIssue: String?
    private var lastDiskIssue: String?

    private lazy var coordinator = SleepCoordinator(
        selected: { [unowned self] in Set(self.selected.keys) },
        mounted: { [unowned self] in self.uniqueVolume($0)?.isMounted },
        unmount: disks.unmount, mount: disks.mount,
        schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() } },
        attachment: { [unowned self] in self.uniqueVolume($0)?.sessionID },
        canMountVolumes: SessionState.canMountVolumes
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [soundKey: true])
        selected = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "DockNap") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "D"
        }
        item.button?.toolTip = "DockNap"
        item.button?.setAccessibilityLabel("DockNap")
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu

        disks.onDisconnect = { [weak self] id in self?.coordinator.volumeDisconnected(id) }
        coordinator.canSignalSafeRemoval = { [weak self] in
            guard let self, UserDefaults.standard.bool(forKey: self.soundKey) else { return false }
            return self.disks.canSignalSafeRemoval() && self.power?.canStartUnmountSound == true
        }
        coordinator.onReadyForSleep = { [weak self] done in
            guard let self else {
                done()
                return
            }
            self.unmountSound.play(completion: done)
        }
        coordinator.onFailure = { [weak self] id, operation in
            guard let self, let name = self.selected[id] else { return }
            self.lastDiskIssue = "Couldn’t \(operation) “\(name)”"
        }
        guard disks.start(onChange: { [weak self] in self?.updateSavedNames() }) else {
            startupIssue = "Disk monitoring is unavailable. Reopen DockNap to retry."
            return
        }
        let monitor = PowerMonitor(onWillSleep: { [weak self] allow in
            guard let self else { allow(); return }
            self.lastDiskIssue = nil
            self.coordinator.willSleep(allow: allow)
        }, onDidWake: { [weak self] in
            self?.unmountSound.cancel()
            self?.coordinator.didWake()
        })
        power = monitor
        if !monitor.start() { startupIssue = "Sleep monitoring is unavailable. Reopen DockNap to retry." }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unmountSound.cancel()
        power?.stop()
    }

    private func uniqueVolume(_ id: String) -> ExternalVolume? {
        disks.volumes.first { $0.id == id && !$0.isAmbiguous }
    }

    private func updateSavedNames() {
        var renamed = false
        for volume in disks.volumes where !volume.isAmbiguous {
            if let saved = selected[volume.id], saved != volume.name {
                selected[volume.id] = volume.name
                renamed = true
            }
        }
        if renamed { UserDefaults.standard.set(selected, forKey: defaultsKey) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let connected = disks.volumes
        let visibleIDs = Set(connected.map(\.id))
        let byName = Dictionary(grouping: connected, by: \.name)
        addLabel("Volumes to Unmount on Sleep")
        if connected.isEmpty { addLabel("No external volumes connected") }
        for volume in connected {
            var title = volume.name
            if byName[volume.name, default: []].count > 1 {
                title += " (\(volume.id.prefix(8)))"
            }
            if volume.isAmbiguous { title += " — Duplicate UUID" }
            else if !volume.isMounted { title += " — Unmounted" }
            addVolume(title, id: volume.id, enabled: !volume.isAmbiguous || selected[volume.id] != nil)
        }
        for (id, name) in selected.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) where !visibleIDs.contains(id) {
            addVolume("\(name) — Disconnected", id: id, enabled: true)
        }
        if let issue = startupIssue ?? lastDiskIssue {
            menu.addItem(.separator())
            addLabel(issue)
        }
        menu.addItem(.separator())
        let sound = addAction("Play Unmount Sound", #selector(toggleSound))
        sound.state = UserDefaults.standard.bool(forKey: soundKey) ? .on : .off
        let login = addAction("Launch at Login", #selector(toggleLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval:
            login.title = "Allow Launch at Login…"
            login.state = .mixed
        default: break
        }
        menu.addItem(.separator())
        _ = addAction("About DockNap", #selector(about))
        let quit = addAction("Quit DockNap", #selector(quitApp))
        quit.keyEquivalent = "q"
    }

    private func addLabel(_ title: String) {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
    }

    private func addAction(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func addVolume(_ title: String, id: String, enabled: Bool) {
        let item = addAction(title, #selector(toggleVolume(_:)))
        item.representedObject = id
        item.state = selected[id] == nil ? .off : .on
        item.isEnabled = enabled
    }

    @objc private func toggleVolume(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if selected.removeValue(forKey: id) != nil {
            coordinator.selectionRemoved(id)
        } else if let volume = uniqueVolume(id) {
            selected[id] = volume.name
        }
        UserDefaults.standard.set(selected, forKey: defaultsKey)
    }

    @objc private func toggleSound() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: soundKey), forKey: soundKey)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = "Keep DockNap in your Applications folder and check Login Items in System Settings."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

if CommandLine.arguments.dropFirst().elementsEqual([UnmountSound.helperArgument]) {
    exit(ChimePlayback().run() ? EXIT_SUCCESS : EXIT_FAILURE)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = appDelegate
app.run()
