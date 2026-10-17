import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Hides the Dock by making its auto-hide reveal delay effectively infinite.
/// Reads and writes the Dock's preferences directly; only restarting the Dock needs a process.
enum Dock {
    private static let domain = "com.apple.dock" as CFString
    private static let hiddenDelay = 1000.0

    /// Every Dock preference Dockless changes while hiding, and the value it sets.
    /// Bouncing icons (app launches, apps wanting attention) would otherwise pop the hidden Dock up.
    private static let managed: [(key: String, value: Any)] = [
        ("autohide", true),
        ("autohide-delay", hiddenDelay),
        ("no-bouncing", true),
        ("launchanim", false),
    ]

    static var isHidden: Bool {
        CFPreferencesAppSynchronize(domain)
        return (value("autohide-delay") as? Double ?? 0) >= 100 && (value("autohide") as? Bool ?? false)
    }

    /// Hidden with every managed preference in place (false after upgrading from a version that set fewer).
    static var isFullyHidden: Bool {
        CFPreferencesAppSynchronize(domain)
        return managed.allSatisfy { (value($0.key) as? NSObject)?.isEqual($0.value) ?? false }
    }

    /// The user's own values, saved the first time Dockless overrides each key. A key in `savedKeys`
    /// but missing from `originals` was unset originally and gets deleted again on restore.
    private static var originals: [String: Any] {
        get { UserDefaults.standard.dictionary(forKey: "originals") ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "originals") }
    }
    private static var savedKeys: [String] {
        get { UserDefaults.standard.stringArray(forKey: "savedKeys") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "savedKeys") }
    }

    static func setHidden(_ hidden: Bool) {
        migrate()
        var saved = savedKeys
        var orig = originals
        if hidden {
            for (key, newValue) in managed {
                if !saved.contains(key) {
                    saved.append(key)
                    orig[key] = value(key)
                }
                set(key, newValue)
            }
        } else {
            for (key, _) in managed where saved.contains(key) {
                set(key, orig[key])
                orig[key] = nil
            }
            saved = []
        }
        savedKeys = saved
        originals = orig
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    /// Earlier versions saved only autohide and its delay, under separate keys.
    private static func migrate() {
        let d = UserDefaults.standard
        guard let autohide = d.object(forKey: "originalAutohide") as? Bool else { return }
        var orig = originals
        var saved = savedKeys
        orig["autohide"] = autohide
        orig["autohide-delay"] = d.object(forKey: "originalDelay")
        for key in ["autohide", "autohide-delay"] where !saved.contains(key) { saved.append(key) }
        originals = orig
        savedKeys = saved
        d.removeObject(forKey: "originalAutohide")
        d.removeObject(forKey: "originalDelay")
    }

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    /// nil deletes the key.
    private static func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var signalSources: [DispatchSourceSignal] = []
    private let d = UserDefaults.standard

    private var restoreOnQuit: Bool {
        get { d.object(forKey: "restoreOnQuit") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreOnQuit") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Re-apply the last choice (e.g. after a login or a crash that restored nothing).
        if d.bool(forKey: "wantHidden") && !Dock.isFullyHidden { Dock.setHidden(true) }
        installHotKeyHandler()
        registerHotKey()
        // The hotkey follows the layout, so re-bind it when the layout changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.registerHotKey() } }
        refresh()
        // Handle termination signals on the main queue (not in signal context), restoring the Dock first.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.restoreOnQuit ?? true, Dock.isHidden { Dock.setHidden(false) }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if restoreOnQuit && Dock.isHidden { Dock.setHidden(false) }
    }

    @objc func toggle() {
        let hide = !Dock.isHidden
        Dock.setHidden(hide)
        d.set(hide, forKey: "wantHidden")
        refresh()
    }

    private func refresh() {
        let hidden = Dock.isHidden
        statusItem.button?.image = NSImage(systemSymbolName: hidden ? "dock.arrow.down.rectangle" : "dock.rectangle",
                                           accessibilityDescription: "Dockless")?
            // Match the size of the system's own menu bar icons (symbols default to a smaller size).
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Hide Dock", action: #selector(toggle), keyEquivalent: "d")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.state = hidden ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let restore = NSMenuItem(title: "Show Dock When Quitting", action: #selector(toggleRestore), keyEquivalent: "")
        restore.state = restoreOnQuit ? .on : .off
        restore.target = self
        menu.addItem(restore)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dockless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleRestore() {
        restoreOnQuit.toggle()
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Dockless: login item error \(error)") }
        refresh()
    }

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// ⌃⌥⌘D toggles the Dock from anywhere (no permissions needed).
    func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let id = EventHotKeyID(signature: OSType(0x444B4C53), id: 1) // "DKLS"
        let status = RegisterEventHotKey(UInt32(Self.keyCode(for: "d") ?? kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey),
                                         id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("Dockless: couldn't register ⌃⌥⌘D (\(status)); it may be taken by another app") }
    }
}

extension AppDelegate {
    /// The key that types `char` in the active layout (so the shortcut follows Colemak, Dvorak, etc.).
    static func keyCode(for char: Character) -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buf -> Int? in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<UInt16(128) {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                     OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr,
                      length == 1, let scalar = UnicodeScalar(chars[0]), Character(scalar) == char else { continue }
                return Int(code)
            }
            return nil
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
