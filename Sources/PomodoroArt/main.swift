import AppKit
@preconcurrency import WebKit
import UserNotifications

private var verificationExitCode: Int32 = 0

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, UNUserNotificationCenterDelegate {
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private lazy var storage = AppStorage()
    private let interfaceURL = Bundle.main.resourceURL!.appendingPathComponent("Panel.html")
    private var ready = false
    private var awaitingStageConfirmation = false
    private var popoverIsClosing = false
    private var pendingCompletionPresentation = false
    private var deadlineTimer: Timer?
    private var dayTimer: Timer?
    private var activity: NSObjectProtocol?
    private var notificationGeneration = 0
    private let notificationID = "pomodoro-countdown"
    private let notifications = UNUserNotificationCenter.current()
    private let verifying = CommandLine.arguments.contains("--verify-app") || CommandLine.arguments.contains("--verify-intro")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notifications.delegate = self
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationID])
        setupMenu()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
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
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshDailyCount), name: name, object: nil)
        }
        if !verifying { enableNotifications() }
        if verifying {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            storage = AppStorage(directory: folder)
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
        let introduction = CommandLine.arguments.contains("--verify-intro") || (!verifying && !UserDefaults.standard.bool(forKey: "completedIntroduction"))
        setIntroductionVisible(introduction)
        showPopover()
        if CommandLine.arguments.contains("--verify-intro") { verifyIntroduction() }
        else if verifying { verifyApp() }
        else { refreshNotificationPermission() }
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
            case "showIntroduction": setIntroductionVisible(true)
            case "finishIntroduction":
                if !verifying { UserDefaults.standard.set(true, forKey: "completedIntroduction") }
                setIntroductionVisible(false)
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
            setIntroductionVisible(false)
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
            refreshDailyCount()
            if !verifying { refreshNotificationPermission() }
        }
    }

    private func setIntroductionVisible(_ visible: Bool) {
        webView.evaluateJavaScript("window.pomodoroApp?.showIntroduction(\(visible ? "true" : "false"))")
    }

    private func verifyIntroduction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.webView.evaluateJavaScript("document.documentElement.classList.contains('introducing') && !running && !document.getElementById('introduction').hidden") { result, error in
                guard error == nil, result as? Bool == true else {
                    self.finishVerification(false, "Introduction did not open without starting a timer"); return
                }
                if let window = self.popover.contentViewController?.view.window {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/pomodoro-introduction.png"]
                    try? capture.run()
                    capture.waitUntilExit()
                }
                self.webView.evaluateJavaScript("document.getElementById('intro-start').click()") { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.webView.evaluateJavaScript("!document.documentElement.classList.contains('introducing') && !running") { result, error in
                            self.finishVerification(error == nil && result as? Bool == true, "First-launch introduction and Open timer action")
                        }
                    }
                }
            }
        }
    }

    // Exercise the WebKit bridge and hidden countdown without recording a session.
    private func verifyApp() {
        let setup = """
        (async () => {
        const blockedConnection = new Promise((resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error('Network policy was not enforced')), 2000);
          document.addEventListener('securitypolicyviolation', event => {
            if (event.violatedDirective === 'connect-src') { clearTimeout(timeout); resolve(true); }
          }, { once: true });
        });
        fetch('https://example.invalid/pomodoro-network-check').catch(() => {});
        await blockedConnection;
        const originalReadStorage = readStorage;
        const pendingDays = [];
        readStorage = () => new Promise(resolve => pendingDays.push(data => resolve({ ok: true, json: async () => data })));
        const day = (date, count) => ({ date, count, dayEndsAt: Date.now() + 60000 });
        try {
          const yesterday = loadCycleLogFromDisk();
          const midnight = loadCycleLogFromDisk();
          pendingDays[1](day('2030-01-02', 0));
          await midnight;
          pendingDays[0](day('2030-01-01', 8));
          await yesterday;
          if (completedCycles !== 0 || cycleLog.children.length !== 0) throw new Error('Late reply restored yesterday’s rounds');
          const completion = recordCompletedCycle();
          pendingDays[2](day('2030-01-02', 1));
          await completion;
          if (completedCycles !== 1) throw new Error('New-day completion was not displayed');
          const expired = loadCycleLogFromDisk();
          pendingDays[3]({ date: '2030-01-01', count: 9, dayEndsAt: Date.now() - 1 });
          await new Promise(resolve => setTimeout(resolve, 0));
          pendingDays[4](day('2030-01-02', 1));
          await expired;
          if (completedCycles !== 1) throw new Error('Expired reply restored yesterday’s count');
          for (const state of ['focus-finished', 'break-running', 'break-paused']) {
            modeIndex = state === 'focus-finished' ? 0 : 1;
            awaitingConfirmation = state === 'focus-finished';
            if (state === 'break-running') start();
            reset();
            if (running || awaitingConfirmation || modeIndex !== 0 || remaining !== modes[0].seconds || completedCycles !== 1)
              throw new Error('Reset did not abandon the unfinished round and restore fresh focus');
          }
        } finally { readStorage = originalReadStorage; }
        await loadCycleLogFromDisk();
        if (completedCycles !== 0) throw new Error('Interrupted round was recorded');
        const focusBar = document.getElementById('focus-duration');
        const restBar = document.getElementById('break-duration');
        if (focusBar.max !== '10800') throw new Error('Focus limit must be three hours');
        for (const bar of [focusBar, restBar]) {
          const index = bar === focusBar ? 0 : 1;
          bar.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
          bar.value = '1790';
          bar.dispatchEvent(new Event('input', { bubbles: true }));
          if (modes[index].seconds !== 1800) throw new Error('Dragging must reach exactly 30 minutes');
          window.dispatchEvent(new PointerEvent('pointerup'));
        }
        focusBar.dispatchEvent(new WheelEvent('wheel', { deltaY: -1, cancelable: true }));
        if (modes[0].seconds !== 1810) throw new Error('Scroll must adjust by ten seconds');
        focusBar.dispatchEvent(new WheelEvent('wheel', { deltaY: 1, cancelable: true }));
        if (modes[0].seconds !== 1800) throw new Error('Scroll must return to exactly 30 minutes');
        durationDrag = { index: 0, fine: true, x: 100, seconds: 1790 };
        focusBar.dispatchEvent(new PointerEvent('pointermove', { clientX: 102, cancelable: true }));
        if (modes[0].seconds !== 1800) throw new Error('Fine dragging must reach ten-second steps');
        window.dispatchEvent(new PointerEvent('pointerup'));
        for (const seconds of [10, 1790, 1800, 1810, 10790, 10800]) {
          focusBar.value = String(seconds);
          focusBar.dispatchEvent(new Event('input', { bubbles: true }));
          if (modes[0].seconds !== seconds) throw new Error('Exact bar values must remain reachable');
        }
        await readStorage('settings', { method: 'PUT', body: JSON.stringify({ focusMinutes: 180, breakMinutes: 30 }) });
        const saved = await (await readStorage('settings')).json();
        if (saved.focusMinutes !== 180) throw new Error('Three-hour setting was not saved');
        applyDurationSettings({ focusMinutes: 1 / 6, breakMinutes: 1 / 6 });
        start();
        window.pomodoroApp.setNotificationPermission(true);
        const quit = document.getElementById('native-quit');
        const bounds = quit.getBoundingClientRect();
        const icon = quit.querySelector('svg').getBoundingClientRect();
        const points = [[bounds.width / 2, bounds.height / 2], [1, 1], [bounds.width - 1, 1],
                        [1, bounds.height - 1], [bounds.width - 1, bounds.height - 1]];
        return points.every(([x, y]) => document.elementFromPoint(bounds.left + x, bounds.top + y)?.closest('#native-quit') === quit)
          && Math.abs((icon.left + icon.width / 2) - (bounds.left + bounds.width / 2)) < 0.1
          && Math.abs((icon.top + icon.height / 2) - (bounds.top + bounds.height / 2)) < 0.1
          && document.getElementById('native-notifications').hidden
          && document.getElementById('focus-duration').value === '10'
          && document.getElementById('break-duration').value === '10';
        })();
        """
        webView.callAsyncJavaScript("return await " + setup, arguments: [:], in: nil, in: .page) { response in
            let result: Any?
            let error: Error?
            switch response {
            case .success(let value): result = value; error = nil
            case .failure(let failure): result = nil; error = failure
            }
            guard error == nil, result as? Bool == true else {
                self.finishVerification(false, "Precise slider adjustment or quit hit area check failed: \(error?.localizedDescription ?? "unexpected result")"); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard !self.webView.configuration.websiteDataStore.isPersistent,
                      self.dayTimer?.isValid == true,
                      self.popover.isShown, NSApp.activationPolicy() == .accessory,
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
                                        self.webView.evaluateJavaScript("reset(); !running && !awaitingConfirmation && modeIndex === 0 && remaining === modes[0].seconds") { result, error in
                                            self.finishVerification(error == nil && result as? Bool == true,
                                                "Daily count refresh, stale-response protection, whole-round reset, precise sliders, and completion popovers")
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
    @objc private func refreshDailyCount() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshDailyCount() }
            return
        }
        guard ready else { return }
        webView.evaluateJavaScript("window.pomodoroApp?.refreshDay()")
        dayTimer?.invalidate()
        // Calendar days can be 23 or 25 hours; always use the next local midnight.
        let timer = Timer(fire: storage.nextDayStart, interval: 0, repeats: false) { [weak self] _ in
            self?.refreshDailyCount()
        }
        dayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func didWake() {
        if ready {
            webView.evaluateJavaScript("window.pomodoroApp?.tick()")
            refreshDailyCount()
        }
    }
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
        dayTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
if CommandLine.arguments.contains("--verify-app") || CommandLine.arguments.contains("--verify-intro") { exit(verificationExitCode) }
