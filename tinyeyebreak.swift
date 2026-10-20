// tinyeyebreak.swift: a minimal 20-20-20 eye-break reminder with menu bar cotrols.
//
//   run:   swift tinyeyebreak.swift (or: swiftc -O tinyeyebreak.swift -o tinyeyebreak)

import AppKit

/// The break cadence for the blackout popup.
///
/// Everything is stored in whole seconds. The interval picker shows it as minutes;
// `everySeconds` is the work time between breaks, `breakSeconds` how long the blackout
// stays up.
typealias Settings = (everySeconds: Int, breakSeconds: Int)

/// Take a single-instance lock for an unbundled binary, preventing duplicate instances.
///
/// Parameters
/// ----------
/// path : The lock file to create and hold for the process's lifetime.
///
/// returns: The held file descriptor, or -1 when another instance holds the lock.
func acquireLock(_ path: String) -> Int32 {
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
    if fd >= 0 { close(fd) }
    return -1
}

/// Re-exec the app detached and terminate, unless it already is detached.
///
/// A direct terminal launch immediately returns, with the child receiving its own
/// session (`POSIX_SPAWN_SETSID`) and /dev/null stdio. Skipped when already detached,
// when launchd is the parent, and under `swift tinyeyebreak.swift`.
///
/// returns: Nothing on the detached path. Otherwise the process exits 0 without return.
func detachIfInteractive() {
    if getenv("TINYBREAK_DETACHED") != nil { return }
    if getppid() == 1 { return }  // launchd: LaunchAgent semantics
    let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
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
    private var wantRunning = true
    private var timer: Timer?
    private var overlays: [NSWindow] = []
    private var activity: NSObjectProtocol?  // App Nap opt-out; must stay retained
    private var statusItem: NSStatusItem?
    private var lastStatus = ""
    private var pausedUntil: Date?  // non-nil: Pause's one-hour auto-resume
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

    /// Arm a one-shot main-run-loop timer.
    ///
    /// The `.common` mode keeps the timer firing during event tracking
    /// (open menus, drags), where `.default` would stall.
    ///
    /// Parameters
    /// ----------
    /// seconds : Delay in whole seconds before the selector fires.
    /// selector : The method to invoke on self when the timer fires.
    ///
    /// returns: Nothing. The previous timer, if any, is replaced.
    private func schedule(after seconds: Int, selector: Selector) {
        timer = Timer(
            timeInterval: Double(seconds), target: self, selector: selector,
            userInfo: nil, repeats: false)
        RunLoop.main.add(timer!, forMode: .common)
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
        for screen in screens {
            let window = BlackoutWindow(
                contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            if screen == keyScreen {
                window.contentView = BlackoutView(
                    cancelAction: #selector(endBreak), target: self)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
            overlays.append(window)
        }
        schedule(after: settings.breakSeconds, selector: #selector(endBreak))
        refreshStatus()
    }

    /// Clear the blackout and restart the work cycle.
    @MainActor @objc private func endBreak() {
        guard !overlays.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        if wantRunning { scheduleWork() }
        refreshStatus()
    }

    /// Handle waking from sleep.
    ///
    /// If the overdue work timer already ran `beginBreak`, tear the overlays down
    /// rather than let a break continue.
    @MainActor @objc private func woke() {
        overlays.forEach { $0.orderOut(nil) }  // never blackout a waking screen
        overlays.removeAll()
        timer?.invalidate()
        if wantRunning {
            scheduleWork(afterWake: true)
        } else if let until = pausedUntil {
            if Date() >= until {
                resume(afterWake: true)
            } else {
                schedule(
                    after: max(1, Int(until.timeIntervalSinceNow.rounded())),
                    selector: #selector(resumeFromPause))
            }
        }
    }

    /// Pause for one hour, or resume early.
    @MainActor @objc private func toggle_pause() {
        if wantRunning {
            wantRunning = false
            pausedUntil = Date().addingTimeInterval(3600)
            timer?.invalidate()
            timer = nil
            overlays.forEach { $0.orderOut(nil) }
            overlays.removeAll()
            schedule(after: 3600, selector: #selector(resumeFromPause))
        } else {
            resume(afterWake: false)
        }
        refreshStatus()
    }

    /// Timer entry point for the auto-resume.
    @MainActor @objc private func resumeFromPause() { resume(afterWake: false) }

    /// End a pause, whether its deadline arrived or the user beat it.
    ///
    /// returns: Nothing. Resuming after a wake keeps the 60 s grace.
    @MainActor private func resume(afterWake: Bool) {
        guard !wantRunning else { return }
        wantRunning = true
        pausedUntil = nil
        timer?.invalidate()  // the auto-resume timer, if still armed
        scheduleWork(afterWake: afterWake)
        refreshStatus()
    }

    /// Apply a picker choice and restart the work timer.
    ///
    /// Parameters
    /// ----------
    /// sender : The chosen menu item {`representedObject`: field, `tag`: value}
    @MainActor @objc private func pickSetting(_ sender: NSMenuItem) {
        if sender.representedObject as? String == "every" {
            settings.everySeconds = sender.tag * 60  // the picker speaks minutes
        } else {
            settings.breakSeconds = sender.tag
        }
        if wantRunning, overlays.isEmpty {
            timer?.invalidate()
            scheduleWork()
        }
        refreshStatus()
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
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let plist: [String: Any] = [
                "Label": "local.tinyeyebreak",
                "ProgramArguments": [exe],
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
        let text =
            !wantRunning
            ? pausedUntil.map { "Paused: resumes at " + Self.clock.string(from: $0) } ?? "Paused"
            : (overlays.isEmpty
                ? "Running: every \(settings.everySeconds / 60) min, "
                    + "break \(settings.breakSeconds) s"
                : "On break")
        statusItem?.button?.appearsDisabled = !wantRunning
        if text != lastStatus {
            lastStatus = text
            rebuildMenu()
        }
    }

    /// Rebuild the entire menu from current state.
    @MainActor private func rebuildMenu() {
        let menu = NSMenu()
        let state = NSMenuItem(title: lastStatus, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let toggleItem = menu.addItem(
            withTitle: wantRunning ? "Pause for one hour" : "Resume",
            action: #selector(toggle_pause), keyEquivalent: "p")
        toggleItem.target = self
        for (label, kind, values, current) in [
            ("Break every…", "every", [10, 15, 20, 30, 45], settings.everySeconds / 60),
            ("Break length…", "break", [10, 15, 20, 30, 60], settings.breakSeconds),
        ] {
            let parent = menu.addItem(withTitle: label, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for v in values {
                let item = NSMenuItem(
                    title: "\(v)\(kind == "every" ? " min" : " s")",
                    action: #selector(pickSetting(_:)), keyEquivalent: "")
                item.target = self
                item.tag = v
                item.representedObject = kind
                item.state = v == current ? .on : .off
                sub.addItem(item)
            }
            parent.submenu = sub
        }
        menu.addItem(.separator())
        let login = menu.addItem(
            withTitle: "Launch at Login",
            action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLoginEnabled() ? .on : .off
        let quitItem = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusItem?.menu = menu
    }

    /// Terminates the app.
    @MainActor @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The black content view holding the Cancel button.
final class BlackoutView: NSView {
    /// Build the blackout content for one screen.
    ///
    /// Parameters
    /// ----------
    /// cancelAction : The selector invoked when Cancel is clicked.
    /// target : The object receiving `cancelAction`.
    ///
    /// returns: The ready view: black, with Cancel as its only subview, in lower left.
    init(cancelAction: Selector, target: Any) {
        super.init(frame: .zero)
        let cancel = NSButton(title: "Cancel", target: target, action: cancelAction)
        cancel.keyEquivalent = "\u{1b}"  // Esc cancels as well
        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)  // bezel sizes to it
        cancel.font = font
        cancel.appearance = NSAppearance(named: .vibrantDark)
        cancel.attributedTitle = NSAttributedString(
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
if acquireLock(NSHomeDirectory() + "/Library/Caches/tinyeyebreak.lock") < 0 {
    fputs("tinyeyebreak: already running\n", stderr)
    exit(0)
}

let app = NSApplication.shared
let controller = TinyEyeBreak()  // run() never returns; keeps it alive
app.delegate = controller
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon
app.run()

