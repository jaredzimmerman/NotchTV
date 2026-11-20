import AppKit
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helper = HelperBridge()
    private let overlay = NotchOverlay()
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?
    private var rescanWork: DispatchWorkItem?

    /// What the helper last told us.
    private var deviceName: String?
    private var playState: String?  // playing | paused | idle | unknown
    private var pushesLive = false  // a playstate event has arrived since the last connect
    private var lastError: String?
    private var unpaired: [(id: String, name: String)] = []
    private var pairingName: String?
    private var didHintPairing = false

    private var toggleInFlight = false
    private var requestID = 0  // echoed by the helper, so a late reply can't answer a newer click
    private var toggleTimeout: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.write("NotchTV launched")
        guard Self.builtInDisplayMightHaveNotch() else {
            let alert = NSAlert()
            alert.messageText = "NotchTV needs a Mac with a notch"
            alert.informativeText = "This Mac's built-in display doesn't have one."
            alert.addButton(withTitle: "Quit")
            NSApp.activate()
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        overlay.onClick = { [weak self] in self?.click() }
        overlay.onMenu = { [weak self] event in self?.showMenu(event) }
        layout()
        updateWings(animated: false)

        helper.onMessage = { [weak self] in self?.handle($0) }
        helper.onExit = { [weak self] in self?.helperExited() }
        helper.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(layout),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        watchNetwork()
        registerLoginItemOnce()
    }

    func applicationWillTerminate(_ note: Notification) {
        helper.stop()
    }

    // MARK: Layout

    /// False only when the built-in display is on and has no notch. With the lid closed
    /// there is no built-in screen to ask, so keep running until it reappears.
    private static func builtInDisplayMightHaveNotch() -> Bool {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) != 0 else { continue }
            return screen.safeAreaInsets.top > 0
        }
        return true
    }

    @objc private func layout() {
        let screen = NotchGeometry.notchScreen()
        let notch = screen.flatMap(NotchGeometry.notchRect(on:))
        if let notch { Log.write("notch at \(NSStringFromRect(notch))") } else { Log.write("no notch screen") }
        overlay.place(over: notch, scale: screen?.backingScaleFactor ?? 2)
    }

    /// Right wing = what a click will do; left wing = the TV, dimmed when none is connected.
    private func updateWings(animated: Bool) {
        overlay.setDeviceAvailable(deviceName != nil)
        let symbol: String
        if deviceName != nil {
            switch playState {
            case "playing": symbol = "pause.fill"
            case "paused", "idle": symbol = "play.fill"
            default: symbol = "playpause.fill"
            }
        } else if unpaired.count == 1 {
            symbol = "plus"  // a click pairs it (with several, pairing is in the right-click menu)
        } else {
            symbol = lastError == nil ? "ellipsis" : "exclamationmark"
        }
        overlay.setNextAction(symbol, animated: animated)
    }

    // MARK: Clicks

    private func click() {
        guard helper.isInstalled else {
            overlay.showMessage("exclamationmark.triangle.fill", "Helper not installed")
            return
        }
        if !helper.isRunning { helper.start() }  // skip any restart backoff
        guard helper.isRunning else {
            overlay.showMessage("exclamationmark.triangle.fill", "Helper didn't start")
            return
        }
        if deviceName == nil, pairingName == nil, let only = unpaired.first, unpaired.count == 1 {
            beginPairing(id: only.id, name: only.name)
            return
        }
        guard !toggleInFlight else { return }
        toggleInFlight = true
        requestID += 1
        helper.send("toggle \(requestID)")
        overlay.setBusy(true)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.toggleInFlight else { return }
            self.finishToggle()
            self.overlay.showMessage("exclamationmark.triangle.fill", self.unreachableText)
        }
        toggleTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func finishToggle() {
        toggleInFlight = false
        toggleTimeout?.cancel()
        overlay.setBusy(false)
    }

    private var unreachableText: String {
        if let deviceName { return "Can't reach \(deviceName)" }
        return "No Apple TV"
    }

    // MARK: Helper messages

    private func handle(_ msg: [String: Any]) {
        if let ok = msg["ok"] as? Bool {
            guard toggleInFlight, msg["req"] as? String == String(requestID) else { return }
            finishToggle()
            if ok {
                // The reply's state is the helper's prediction. Once live pushes are flowing they
                // report what really happened (an idle TV ignores play), so trust them instead.
                if !pushesLive, let state = msg["state"] as? String, state != "unknown" { playState = state }
                updateWings(animated: true)
            } else {
                overlay.showMessage("exclamationmark.triangle.fill", unreachableText)
            }
            return
        }

        switch msg["event"] as? String {
        case "ready":
            deviceName = msg["name"] as? String
            lastError = nil
            unpaired = []
            pushesLive = false
        case "playstate":
            playState = msg["state"] as? String
            pushesLive = true
        case "searching":
            deviceName = nil
            playState = nil
            pushesLive = false
            lastError = nil
            unpaired = []
        case "error":
            deviceName = nil
            playState = nil
            pushesLive = false
            unpaired = []  // e.g. a new network with no Apple TV: don't offer the old one
            lastError = msg["error"] as? String
        case "unpaired":
            deviceName = nil
            let devices = msg["devices"] as? [[String: Any]] ?? []
            unpaired = devices.compactMap { d in
                guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
                return (id, name)
            }
            // First time an unpaired TV shows up (first launch, or a new place): say how to start.
            if !didHintPairing, pairingName == nil, let first = unpaired.first {
                didHintPairing = true
                overlay.showMessage("appletv", unpaired.count == 1 ? "Click to pair \(first.name)"
                                                                   : "Right-click to pair an Apple TV",
                                    hold: 5)
            }
        case "pin_needed":
            let name = msg["name"] as? String ?? "Apple TV"
            let step = msg["step"] as? Int ?? 1
            // Let this message finish before running a modal.
            DispatchQueue.main.async { [weak self] in self?.askForPIN(name: name, step: step) }
        case "paired":
            pairingName = nil
            unpaired = []
            overlay.showMessage("checkmark", "Paired \(msg["name"] as? String ?? "")", hold: 1.8)
        case "pair_failed":
            pairingName = nil
            overlay.showMessage("exclamationmark.triangle.fill", "Pairing failed")
        case "pair_cancelled":
            pairingName = nil
            overlay.hideMessage()
        default:
            break
        }
        updateWings(animated: true)
    }

    private func helperExited() {
        if toggleInFlight {
            finishToggle()
            overlay.showMessage("exclamationmark.triangle.fill", unreachableText)
        }
        if pairingName != nil {
            overlay.showMessage("exclamationmark.triangle.fill", "Pairing failed")
        }
        deviceName = nil
        playState = nil
        pushesLive = false
        pairingName = nil
        updateWings(animated: false)
    }

    // MARK: Pairing

    private func beginPairing(id: String, name: String) {
        pairingName = name
        overlay.showMessage("appletv", "Pairing \(name)", hold: nil)
        helper.send("pair \(id)")
    }

    private func askForPIN(name: String, step: Int) {
        overlay.hideMessage()
        let alert = NSAlert()
        alert.messageText = step == 1 ? "Enter the PIN shown on \(name)" : "Enter the new PIN shown on \(name)"
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        field.placeholderString = "PIN"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if let icon = NSImage(systemSymbolName: "appletv", accessibilityDescription: nil) {
            alert.icon = icon
        }
        NSApp.activate()
        let response = alert.runModal()
        let pin = field.stringValue.filter(\.isNumber)
        if response == .alertFirstButtonReturn, !pin.isEmpty {
            overlay.showMessage("ellipsis", "Pairing \(name)", hold: nil)
            helper.send("pin \(pin)")
        } else {
            pairingName = nil
            helper.send("cancel_pair")
        }
    }

    // MARK: Menu

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let current = NSMenuItem(title: deviceName ?? (unpaired.isEmpty ? "No Apple TV" : "Not paired"),
                                 action: nil, keyEquivalent: "")
        current.isEnabled = false
        current.image = NSImage(systemSymbolName: "appletv", accessibilityDescription: nil)
        menu.addItem(current)

        for device in unpaired {
            let item = NSMenuItem(title: "Pair \(device.name)…", action: #selector(pairFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = [device.id, device.name]
            item.isEnabled = pairingName == nil
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit NotchTV", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: overlay.menuAnchor)
    }

    @objc private func pairFromMenu(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        beginPairing(id: pair[0], name: pair[1])
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("login item: \(error)")
            overlay.showMessage("exclamationmark.triangle.fill", "Couldn't change Open at Login")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func registerLoginItemOnce() {
        let key = "didOfferLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do { try SMAppService.mainApp.register() } catch { Log.write("login item: \(error)") }
    }

    // MARK: Network changes → look for the Apple TV on the new network

    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name))|\(path.gateways)"
            DispatchQueue.main.async { self?.networkChanged(signature, satisfied: path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "NotchTV.path"))
    }

    private func networkChanged(_ signature: String, satisfied: Bool) {
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature, satisfied else { return }
        scheduleRescan(after: 2)
    }

    @objc private func didWake() { scheduleRescan(after: 3) }

    private func scheduleRescan(after delay: TimeInterval) {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.write("rescan")
            self?.helper.send("rescan")
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
