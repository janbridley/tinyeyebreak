// tinyeyebreak.swift: a minimal 20-20-20 eye-break reminder with menu bar controls.
//
//   run:   swift tinyeyebreak.swift (or: swiftc -O tinyeyebreak.swift -o tinyeyebreak)

import AppKit

/// The break cadence for the blackout popup.
///
/// Everything is stored in whole seconds. The interval picker shows it as minutes;
/// `everySeconds` is the work time between breaks, `breakSeconds` how long the blackout
/// stays up.
typealias Settings = (everySeconds: Int, breakSeconds: Int)

/// This binary's absolute path, for re-exec and the LaunchAgent plist.
func currentExecutable() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

/// Take a single-instance lock for an unbundled binary, preventing duplicate instances.
///
/// Parameters
/// ----------
/// path : The lock file to create and hold for the process's lifetime.
///
/// returns: True when this process holds the lock.
func acquireLock(_ path: String) -> Bool {
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if fd >= 0 { close(fd) }
        return false
    }
    return true
}

/// Re-exec the app detached and terminate, unless it already is detached.
///
/// A direct terminal launch immediately returns, with the child receiving its own
/// session (`POSIX_SPAWN_SETSID`) and /dev/null stdio. Skipped when already detached,
/// when launchd is the parent, and under `swift tinyeyebreak.swift`.
///
/// returns: Nothing on the detached path. Otherwise the process exits 0 without return.
func detachIfInteractive() {
    if getenv("TINYBREAK_DETACHED") != nil { return }
    if getppid() == 1 { return }  // launchd: LaunchAgent semantics
    let argv0 = currentExecutable()
    guard argv0.pathExtension != "swift" else { return }
    setenv("TINYBREAK_DETACHED", "1", 1)
    var pid: pid_t = 0
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_RDWR, 0)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0.path), nil]
    defer { argv.forEach { free($0) } }
    if posix_spawn(&pid, argv0.path, &actions, &attr, &argv, environ) == 0 {
        exit(0)
    }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    // Spawn failed: fall through and run in the foreground after all.
}

/// A borderless window that can take keyboard focus.
///
/// Borderless windows refuse key status by default; key is what makes the
/// Cancel button (and its Esc key equivalent) receive events.
final class BlackoutWindow: NSWindow {
    /// Reports whether the window can become key.
    ///
    /// returns: Always true, so the Cancel button can receive events.
    override var canBecomeKey: Bool { true }
}

/// Run the break cadence and own the menu bar, as application delegate.
///
/// On launch it opts out of App Nap, registers for wake notifications,
/// installs the status item, and schedules the first break; each break is
/// one blackout window per screen, torn down together.
final class TinyEyeBreak: NSObject, NSApplicationDelegate {
    private var settings: Settings = (everySeconds: 20 * 60, breakSeconds: 20)
    private var overlays: [NSWindow] = []
    private var timer: Timer?
    private var activity: NSObjectProtocol?  // App Nap opt-out; must stay retained
    private var statusItem: NSStatusItem?
    private var lastStatus = ""
    private var pausedUntil: Date?  // non-nil: Pause's one-hour auto-resume
    private var isPaused: Bool { pausedUntil != nil }
    private let agentPlist =
        NSHomeDirectory()
        + "/Library/LaunchAgents/local.tinyeyebreak.plist"

    /// Set up the status item and the first work timer.
    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image =
            NSImage(systemSymbolName: "eye", accessibilityDescription: "tinyeyebreak")

        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "eye-break timer")
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)

        refreshStatus()
        scheduleWork()
    }

    /// Arm a one-shot main-run-loop timer, replacing any timer already armed.
    ///
    /// The `.common` mode keeps the timer firing during event tracking
    /// (open menus, drags), where `.default` would stall.
    ///
    /// Parameters
    /// ----------
    /// seconds : Delay in whole seconds before the selector fires.
    /// selector : The method to invoke on self when the timer fires.
    private func schedule(after seconds: Int, selector: Selector) {
        timer?.invalidate()
        let fresh = Timer(
            timeInterval: Double(seconds), target: self, selector: selector,
            userInfo: nil, repeats: false)
        RunLoop.main.add(fresh, forMode: .common)
        timer = fresh
    }

    /// Schedule the next work interval.
    ///
    /// After a wake, the first break is held off for at least 60s.
    private func scheduleWork(afterWake: Bool = false) {
        schedule(
            after: max(settings.everySeconds, afterWake ? 60 : 0),
            selector: #selector(beginBreak))
    }

    /// Black out every screen and arm the break-end timer.
    ///
    /// returns: Nothing. With no screens attached, re-arm the work timer instead.
    @MainActor @objc private func beginBreak() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            scheduleWork()
            return
        }
        NSApp.activate()  // so the key overlay can take clicks
        let mouse = NSEvent.mouseLocation
        let keyScreen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens[0]
        overlays = screens.map { blackoutWindow(on: $0, isKey: $0 == keyScreen) }
        schedule(after: settings.breakSeconds, selector: #selector(endBreak))
        refreshStatus()
    }

    /// One blacked-out window for one screen; only the key screen gets Cancel.
    @MainActor private func blackoutWindow(on screen: NSScreen, isKey: Bool) -> BlackoutWindow {
        let window = BlackoutWindow(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        if isKey {
            window.contentView = BlackoutView(cancelAction: #selector(endBreak), target: self)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        return window
    }

    /// Clear the blackout and restart the work cycle.
    @MainActor @objc private func endBreak() {
        guard !overlays.isEmpty else { return }
        dismissOverlays()
        if !isPaused { scheduleWork() }
        refreshStatus()
    }

    /// Order out and forget every blackout window.
    @MainActor private func dismissOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    /// Handle waking from sleep.
    ///
    /// If the overdue work timer already ran `beginBreak`, tear the overlays down
    /// rather than let a break continue.
    @MainActor @objc private func woke() {
        dismissOverlays()  // never blackout a waking screen
        switch pausedUntil {
        case nil:
            scheduleWork(afterWake: true)
        case .some(let until) where Date() >= until:
            resume(afterWake: true)  // the pause ran out while asleep
        case .some(let until):
            schedule(  // keep waiting out the pause
                after: max(1, Int(until.timeIntervalSinceNow.rounded())),
                selector: #selector(resumeFromPause))
        }
    }

    /// Pause for one hour, or resume early.
    @MainActor @objc private func togglePause() {
        if isPaused {
            resume(afterWake: false)
        } else {
            pausedUntil = Date().addingTimeInterval(3600)
            dismissOverlays()
            schedule(after: 3600, selector: #selector(resumeFromPause))
            refreshStatus()
        }
    }

    /// Timer entry point for the auto-resume.
    @MainActor @objc private func resumeFromPause() { resume(afterWake: false) }

    /// End a pause, whether its deadline arrived or the user beat it.
    ///
    /// returns: Nothing. Resuming after a wake keeps the 60 s grace.
    @MainActor private func resume(afterWake: Bool) {
        guard isPaused else { return }
        pausedUntil = nil
        scheduleWork(afterWake: afterWake)
        refreshStatus()
    }

    /// Apply a picker choice and restart the work timer.
    @MainActor private func applySetting() {
        if !isPaused, overlays.isEmpty { scheduleWork() }
        refreshStatus()
    }

    /// Set the work interval, converting to minutes.
    @MainActor @objc private func pickEvery(_ sender: NSMenuItem) {
        settings.everySeconds = sender.tag * 60
        applySetting()
    }

    /// Set the break length (natively seconds).
    @MainActor @objc private func pickBreak(_ sender: NSMenuItem) {
        settings.breakSeconds = sender.tag
        applySetting()
    }

    /// Launch at login for an unbundled binary: a per-user LaunchAgent.
    //
    /// (NOTE: SMAppService, the modern approach to this, needs an .app bundle).
    ///
    /// returns: True when the agent plist exists on disk.
    private func launchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPlist)
    }

    /// Install or remove the per-user LaunchAgent.
    ///
    /// returns: Nothing. The plist is written or deleted and the menu is redrawn.
    @MainActor @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if launchAtLoginEnabled() {
            try? fm.removeItem(atPath: agentPlist)
        } else {
            let plist: [String: Any] = [
                "Label": "local.tinyeyebreak",
                "ProgramArguments": [currentExecutable().path],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(
                atPath: (agentPlist as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            {
                try? data.write(to: URL(fileURLWithPath: agentPlist))
            }
        }
        rebuildMenu()
    }

    /// Format clock times for the status line.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// Recompute the status line from actual state.
    ///
    /// returns: Nothing. The menu is rebuilt only when the text changes.
    @MainActor private func refreshStatus() {
        let text: String
        switch (pausedUntil, overlays.isEmpty) {
        case (let until?, _):
            text = "Paused: resumes at " + Self.clock.string(from: until)
        case (nil, false):
            text = "On break"
        case (nil, true):
            text =
                "Running: every \(settings.everySeconds / 60) min, "
                + "break \(settings.breakSeconds) s"
        }
        statusItem?.button?.appearsDisabled = isPaused
        if text != lastStatus {
            lastStatus = text
            rebuildMenu()
        }
    }

    /// Build one interval picker submenu with the current choice checked.
    @MainActor private func pickerMenu(
        _ values: [Int], unit: String, current: Int, action: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.items = values.map { v in
            let item = NSMenuItem(title: "\(v) \(unit)", action: action, keyEquivalent: "")
            item.target = self
            item.tag = v
            item.state = v == current ? .on : .off
            return item
        }
        return menu
    }

    /// Rebuild the entire menu from current state.
    @MainActor private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: lastStatus, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(
            withTitle: isPaused ? "Resume" : "Pause for one hour",
            action: #selector(togglePause), keyEquivalent: "p"
        ).target = self
        for (title, values, current, unit, action) in [
            (
                "Break every…", [10, 15, 20, 30, 45], settings.everySeconds / 60, "min",
                #selector(pickEvery(_:))
            ),
            (
                "Break length…", [10, 15, 20, 30, 60], settings.breakSeconds, "s",
                #selector(pickBreak(_:))
            ),
        ] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
                .submenu = pickerMenu(values, unit: unit, current: current, action: action)
        }
        menu.addItem(.separator())
        let login = menu.addItem(
            withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        // Image column, not `state`: macOS 26 auto-assigns Quit an image-column glyph,
        // and state marks render in a wider gutter with padding before the title.
        login.image =
            launchAtLoginEnabled()
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
        menu.addItem(
            withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }
}

/// The black content view holding the Cancel button.
final class BlackoutView: NSView {
    /// Build the blackout content for one screen, with Cancel in the lower left.
    ///
    /// Parameters
    /// ----------
    /// cancelAction : The selector invoked when Cancel is clicked.
    /// target : The object receiving `cancelAction`.
    init(cancelAction: Selector, target: Any) {
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let cancel = NSButton(title: "Cancel", target: target, action: cancelAction)
        cancel.keyEquivalent = "\u{1b}"  // Esc cancels as well
        cancel.appearance = NSAppearance(named: .vibrantDark)
        cancel.attributedTitle = NSAttributedString(  // the bezel sizes to this
            string: "Cancel",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: font,
            ])
        cancel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            cancel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
        ])
    }

    /// Traps; the view is only ever built in code.
    required init?(coder: NSCoder) { fatalError() }
}

detachIfInteractive()
if !acquireLock(NSHomeDirectory() + "/Library/Caches/tinyeyebreak.lock") {
    fputs("tinyeyebreak: already running\n", stderr)
    exit(0)
}

let app = NSApplication.shared
let controller = TinyEyeBreak()  // run() never returns; keeps it alive
app.delegate = controller
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon
app.run()
