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
        return managed.allSatisfy { same(value($0.key), $0.value) }
    }

    /// Preference values compare by value (1000 and 1000.0 are the same); nil means unset.
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
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

    /// Restarts the Dock only if a preference actually changed. A Dock restart rebuilds every full-screen
    /// space, and doing that while apps are going full screen (at login, say) can leave the menu bar stuck
    /// showing in full screen until the next reboot.
    static func setHidden(_ hidden: Bool) {
        migrate()
        CFPreferencesAppSynchronize(domain)
        var saved = savedKeys
        var orig = originals
        var changed = false
        func apply(_ key: String, _ newValue: Any?) {
            if !same(value(key), newValue) { changed = true }
            set(key, newValue)
        }
        if hidden {
            for (key, newValue) in managed {
                if !saved.contains(key) {
                    saved.append(key)
                    orig[key] = value(key)
                }
                apply(key, newValue)
            }
        } else {
            for (key, _) in managed where saved.contains(key) {
                apply(key, orig[key])
                orig[key] = nil
            }
            saved = []
        }
        savedKeys = saved
        originals = orig
        CFPreferencesAppSynchronize(domain)
        if changed { restartDock() }
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

/// Menu bar icon drawn the way most apps do (Claude, for one): a ~16pt template glyph centred on a 24pt canvas,
/// shown in a variable-length status item so the system supplies the standard spacing.
/// With a `tint` the glyph is drawn in that colour instead of following the menu bar.
func menuBarIcon(_ symbol: String, description: String, tint: NSColor? = nil) -> NSImage? {
    guard var glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return nil }
    if let tint, let tinted = glyph.withSymbolConfiguration(.init(paletteColors: [tint])) { glyph = tinted }
    let canvas = NSSize(width: 24, height: 24), box: CGFloat = 20 // symbol images carry ~20% padding: this gives a ~16pt glyph
    let s = box / max(glyph.size.width, glyph.size.height, 1)
    let size = NSSize(width: glyph.size.width * s, height: glyph.size.height * s)
    let image = NSImage(size: canvas, flipped: false) { _ in
        glyph.draw(in: NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                              width: size.width, height: size.height))
        return true
    }
    image.isTemplate = tint == nil
    image.accessibilityDescription = description
    return image
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var signalSources: [DispatchSourceSignal] = []
    private let d = UserDefaults.standard
    private var theme: ThemeFollower?
    /// The utheme palette on screen; nil shows the plain system look.
    private var palette: Palette?
    /// Set when macOS is logging out, restarting or shutting down. Dockless then leaves the Dock hidden
    /// instead of restoring it, so there is no Dock restart on the way out and none again at the next login.
    private var sessionEnding = false

    /// `defaults write com.andples.dockless theme system` stops following utheme.
    private var followsUtheme: Bool { (d.string(forKey: "theme") ?? "utheme") == "utheme" }

    private var restoreOnQuit: Bool {
        get { d.object(forKey: "restoreOnQuit") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreOnQuit") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Re-apply the last choice (e.g. after a login or a crash that restored nothing).
        if d.bool(forKey: "wantHidden") && !Dock.isFullyHidden { Dock.setHidden(true) }
        installHotKeyHandler()
        registerHotKey()
        // The hotkey follows the layout, so re-bind it when the layout changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.registerHotKey() } }
        refresh()
        if followsUtheme {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let t = ThemeFollower(app: "dockless", version: version)
            t.onChange = { [weak self] p in
                self?.palette = p
                self?.refresh()
            }
            theme = t
            t.start()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.sessionEnding = true } }
        // Handle termination signals on the main queue (not in signal context), restoring the Dock first.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreIfQuitting()
                self?.theme?.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreIfQuitting()
        theme?.stop()
    }

    private func restoreIfQuitting() {
        if restoreOnQuit && !sessionEnding && Dock.isHidden { Dock.setHidden(false) }
    }

    @objc func toggle() {
        let hide = !Dock.isHidden
        Dock.setHidden(hide)
        d.set(hide, forKey: "wantHidden")
        refresh()
    }

    private func refresh() {
        let hidden = Dock.isHidden
        // With utheme, the hidden-Dock glyph takes the theme's accent; the shown one keeps following the menu bar.
        statusItem.button?.image = menuBarIcon(hidden ? "dock.arrow.down.rectangle" : "dock.rectangle",
                                               description: "Dockless", tint: hidden ? palette?.color("accent") : nil)
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
        if let palette { style(menu, palette) }
        statusItem.menu = menu
    }

    /// The menu in the theme's light/dark, with its titles in the theme's foreground.
    private func style(_ menu: NSMenu, _ p: Palette) {
        menu.appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
        guard let fg = p.color("foreground") else { return }
        for item in menu.items where !item.isSeparatorItem {
            item.attributedTitle = NSAttributedString(string: item.title,
                                                      attributes: [.foregroundColor: fg, .font: NSFont.menuFont(ofSize: 0)])
        }
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
