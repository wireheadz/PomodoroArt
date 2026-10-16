import AppKit
@preconcurrency import WebKit
import UserNotifications

private var verificationExitCode: Int32 = 0

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, UNUserNotificationCenterDelegate {
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private lazy var storage = AppStorage()
    private let interfaceURL = Bundle.main.resourceURL!.appendingPathComponent("index.html")
    private var ready = false
    private var awaitingStageConfirmation = false
    private var popoverIsClosing = false
    private var pendingCompletionPresentation = false
    private var deadlineTimer: Timer?
    private var activity: NSObjectProtocol?
    private var notificationGeneration = 0
    private let notificationID = "pomodoro-countdown"
    private let notifications = UNUserNotificationCenter.current()
    private let verifying = CommandLine.arguments.contains("--verify-app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notifications.delegate = self
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationID])
        setupMenu()
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "pomodoro")
        config.userContentController.add(self, name: "controls")
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "storage")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        let controller = NSViewController()
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 480))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        controller.view = glass
        webView.frame = glass.bounds
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        glass.addSubview(webView)
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        if !verifying { enableNotifications() }
        if verifying {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            storage = AppStorage(directory: folder, captureFile: folder.appendingPathComponent("capture.json"), vault: folder.appendingPathComponent("no-vault"))
        }
        webView.loadFileURL(interfaceURL, allowingReadAccessTo: interfaceURL.deletingLastPathComponent())
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon(state: "Pausing")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        showPopover()
        if verifying { verifyApp() } else { refreshNotificationPermission() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url?.standardizedFileURL == interfaceURL.standardizedFileURL
        decisionHandler(allowed ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              let request = message.body as? [String: Any], let operation = request["operation"] as? String else {
            replyHandler(nil, "Invalid storage request"); return
        }
        do {
            let result = try storage.handle(operation, method: request["method"] as? String ?? "GET", body: request["body"] as? [String: Any] ?? [:])
            replyHandler(result, nil)
        } catch { replyHandler(nil, error.localizedDescription) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              let body = message.body as? [String: Any] else { return }
        if message.name == "controls" {
            switch body["action"] as? String {
            case "quit": quit()
            case "enableNotifications": openNotificationSettings()
            default: break
            }
            return
        }
        guard let state = body["state"] as? String, ["Working", "Resting", "Pausing"].contains(state) else { return }
        let awaiting = body["awaitingConfirmation"] as? Bool ?? false
        let justCompleted = awaiting && !awaitingStageConfirmation
        awaitingStageConfirmation = awaiting
        if !awaiting { pendingCompletionPresentation = false }
        updateIcon(state: state)
        if justCompleted {
            if popoverIsClosing { pendingCompletionPresentation = true }
            else { showPopover() }
        }
        notificationGeneration += 1
        let generation = notificationGeneration
        deadlineTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        // A completed countdown keeps its scheduled notification. Pause/reset cancels it.
        if !awaiting { notifications.removePendingNotificationRequests(withIdentifiers: [notificationID]) }
        guard state != "Pausing", let timestamp = body["deadline"] as? Double else { return }
        let delay = max(0.1, timestamp / 1000 - Date().timeIntervalSince1970)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Pomodoro countdown")
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.updateIcon(state: "Pausing")
            self?.webView.evaluateJavaScript("window.pomodoroApp?.tick()")
        }
        RunLoop.main.add(deadlineTimer!, forMode: .common)
        if verifying { return }
        notifications.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self, granted, generation == self.notificationGeneration else { return }
                let content = UNMutableNotificationContent()
                let focus = body["mode"] as? String == "Focus"
                content.title = focus ? "Focus finished" : "Break finished"
                content.body = focus ? "Time to rest. Open Pomodoro to start your break." : "Ready to work. Open Pomodoro to start your next focus session."
                content.sound = .default
                let remaining = max(0.1, timestamp / 1000 - Date().timeIntervalSince1970)
                self.notifications.add(UNNotificationRequest(identifier: self.notificationID, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false))) { error in
                    if let error { NSLog("Unable to schedule countdown notification: %@", error.localizedDescription) }
                }
            }
        }
    }

    private func updateIcon(state: String) {
        let label = state == "Pausing" ? "Idle" : state
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            ring.lineWidth = 1.5
            ring.stroke()
            if state == "Working" {
                NSBezierPath(ovalIn: NSRect(x: 6.5, y: 6.5, width: 5, height: 5)).fill()
            } else if state == "Resting" {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 5.5, y: 9))
                line.line(to: NSPoint(x: 12.5, y: 9))
                line.lineWidth = 1.8
                line.lineCapStyle = .round
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Pomodoro — \(label)"
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    func popoverWillClose(_ notification: Notification) { popoverIsClosing = true }
    func popoverDidClose(_ notification: Notification) {
        popoverIsClosing = false
        if pendingCompletionPresentation && awaitingStageConfirmation {
            pendingCompletionPresentation = false
            DispatchQueue.main.async { self.showPopover() }
        }
    }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.isOpaque = false
        popover.contentViewController?.view.window?.backgroundColor = .clear
        popover.contentViewController?.view.window?.makeKey()
        if ready {
            webView.evaluateJavaScript("window.pomodoroApp?.tick()")
            if !verifying { refreshNotificationPermission() }
        }
    }

    // Exercise the WebKit bridge and hidden countdown without recording a session.
    private func verifyApp() {
        let setup = """
        applyDurationSettings({ focusMinutes: 1 / 6, breakMinutes: 1 / 6 });
        start();
        window.pomodoroApp.setNotificationPermission(true);
        const quit = document.getElementById('native-quit');
        const bounds = quit.getBoundingClientRect();
        const icon = quit.querySelector('svg').getBoundingClientRect();
        const points = [[bounds.width / 2, bounds.height / 2], [1, 1], [bounds.width - 1, 1],
                        [1, bounds.height - 1], [bounds.width - 1, bounds.height - 1]];
        points.every(([x, y]) => document.elementFromPoint(bounds.left + x, bounds.top + y)?.closest('#native-quit') === quit)
          && Math.abs((icon.left + icon.width / 2) - (bounds.left + bounds.width / 2)) < 0.1
          && Math.abs((icon.top + icon.height / 2) - (bounds.top + bounds.height / 2)) < 0.1
          && document.getElementById('native-notifications').hidden
          && document.getElementById('focus-duration').value === '10'
          && document.getElementById('break-duration').value === '10';
        """
        webView.evaluateJavaScript(setup) { result, error in
            guard error == nil, result as? Bool == true else {
                self.finishVerification(false, "Quit hit area, icon alignment, or removed test alert check failed"); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard self.popover.isShown, NSApp.activationPolicy() == .accessory,
                      !NSApp.windows.contains(where: { $0.styleMask.contains(.titled) }),
                      let glass = self.popover.contentViewController?.view as? NSVisualEffectView,
                      glass.material == .hudWindow, glass.subviews.count == 1 else {
                    self.finishVerification(false, "Popover, accessory policy, or unexpected audio failed"); return
                }
                self.webView.takeSnapshot(with: nil) { snapshot, error in
                    if let window = self.popover.contentViewController?.view.window {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/pomodoro-glass.png"]
                        try? capture.run()
                        capture.waitUntilExit()
                    }
                    if let snapshot, let tiff = snapshot.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/pomodoro-popover.png"))
                    }
                    self.popover.performClose(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        guard self.popover.isShown else {
                            self.finishVerification(false, "Completion did not open the menu bar popover"); return
                        }
                        self.webView.evaluateJavaScript("awaitingConfirmation && !running && document.getElementById('completion-title').textContent === 'Focus complete' && document.getElementById('completion-continue').textContent === 'Start break'") { result, error in
                            guard error == nil, result as? Bool == true else {
                                self.finishVerification(false, "Hidden countdown did not finish"); return
                            }
                            if let window = self.popover.contentViewController?.view.window {
                                let capture = Process()
                                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/pomodoro-completion.png"]
                                try? capture.run()
                                capture.waitUntilExit()
                            }
                            self.webView.evaluateJavaScript("document.getElementById('completion-continue').click(); running && modeIndex === 1") { result, error in
                                guard error == nil, result as? Bool == true else {
                                    self.finishVerification(false, "Start break button did not advance the timer"); return
                                }
                                self.popover.performClose(nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                                    guard self.popover.isShown else {
                                        self.finishVerification(false, "Break completion did not open the popover"); return
                                    }
                                    self.webView.evaluateJavaScript("document.getElementById('completion-continue').textContent === 'Start focus' && awaitingConfirmation") { result, error in
                                        guard error == nil, result as? Bool == true else {
                                            self.finishVerification(false, "Break completion content was incorrect"); return
                                        }
                                        self.webView.evaluateJavaScript("reset(); !running && !awaitingConfirmation") { result, error in
                                            self.finishVerification(error == nil && result as? Bool == true,
                                                "Automatic anchored popover for focus and break completion, next-stage action, and reset")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishVerification(_ success: Bool, _ description: String) {
        verificationExitCode = success ? 0 : 1
        print("\(success ? "PASS" : "FAIL"): \(description)")
        if !success {
            exit(1)
        }
        NSApp.terminate(nil)
    }
    @objc private func didWake() { if ready { webView.evaluateJavaScript("window.pomodoroApp?.tick()") } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func enableNotifications() {
        notifications.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus == .notDetermined {
                self.notifications.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { NSLog("Notification authorization failed: %@", error.localizedDescription) }
                    self.refreshNotificationPermission()
                }
            } else { self.refreshNotificationPermission() }
        }
    }

    private func refreshNotificationPermission() {
        notifications.getNotificationSettings { [weak self] settings in
            let permitted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                guard let self, self.ready else { return }
                self.webView.evaluateJavaScript("window.pomodoroApp?.setNotificationPermission(\(permitted ? "true" : "false"))")
            }
        }
    }

    private func openNotificationSettings() {
        notifications.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .notDetermined { self.enableNotifications() }
                else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
    }
    private func showError(_ title: String, _ message: String) {
        if ready {
            let payload = [title, message]
            if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.pomodoroApp?.showMessage(...\(json))")
            }
        }
        NSLog("%@: %@", title, message)
        showPopover()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        notificationGeneration += 1
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationID])
        deadlineTimer?.invalidate()
        if verifying { try? FileManager.default.removeItem(at: storage.directory) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showPopover(); completionHandler() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
if CommandLine.arguments.contains("--verify-app") { exit(verificationExitCode) }
