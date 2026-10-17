import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Hides the Dock by making its auto-hide reveal delay effectively infinite.
enum Dock {
    private static let hiddenDelay = "1000"

    static var isHidden: Bool {
        guard let delay = Double(read("autohide-delay") ?? "") else { return false }
        return delay >= 100 && read("autohide") == "1"
    }

    static func setHidden(_ hidden: Bool) {
        let d = UserDefaults.standard
        if hidden {
            // Remember the user's own auto-hide setting so showing the Dock puts it back exactly.
            if !isHidden { d.set(read("autohide") == "1", forKey: "originalAutohide") }
            run("/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "true")
            run("/usr/bin/defaults", "write", "com.apple.dock", "autohide-delay", "-float", hiddenDelay)
        } else {
            run("/usr/bin/defaults", "delete", "com.apple.dock", "autohide-delay")
            let original = d.object(forKey: "originalAutohide") as? Bool ?? true
            run("/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", original ? "true" : "false")
        }
        run("/usr/bin/killall", "Dock")
    }

    private static func read(_ key: String) -> String? {
        let out = run("/usr/bin/defaults", "read", "com.apple.dock", key)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func run(_ path: String, _ args: String...) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private let d = UserDefaults.standard

    private var restoreOnQuit: Bool {
        get { d.object(forKey: "restoreOnQuit") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreOnQuit") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Re-apply the last choice (e.g. after a login or a crash that restored nothing).
        if d.bool(forKey: "wantHidden") && !Dock.isHidden { Dock.setHidden(true) }
        registerHotKey()
        refresh()
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { s in
                if UserDefaults.standard.object(forKey: "restoreOnQuit") as? Bool ?? true { Dock.setHidden(false) }
                signal(s, SIG_DFL)
                raise(s)
            }
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
                                           accessibilityDescription: "Dockless")
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

    /// ⌃⌥⌘D toggles the Dock from anywhere (no permissions needed).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x444B4C53), id: 1) // "DKLS"
        RegisterEventHotKey(UInt32(Self.keyCode(for: "d") ?? kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
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
                      length == 1, Character(UnicodeScalar(chars[0])!) == char else { continue }
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
