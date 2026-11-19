import AppKit

/// A utheme palette, as read from the active generation.
struct Palette {
    let values: [String: String]
    let mode: String
    let generation: String

    var isDark: Bool { mode == "dark" }
    func color(_ key: String) -> NSColor? { values[key].flatMap(NSColor.init(hex:)) }
}

/// Follows utheme live, per its client protocol v1 (utheme/docs/CLIENT-PROTOCOL.md):
/// read palette.json from the resolved `current`, notice switches within a second, and
/// report what's on screen with a heartbeat file. Dockless never writes anywhere else in utheme.
@MainActor
final class ThemeFollower {
    /// nil means "no utheme": Dockless's own (system) look.
    var onChange: ((Palette?) -> Void)?

    private let app: String
    private let version: String
    private let dataDir: URL
    private let current: URL
    private let clientsDir: URL
    private var lastTarget: String?? = .none   // .none = never checked
    private var applied: String?
    private var timer: Timer?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    private static let needs = ["foreground", "accent"]

    init(app: String, version: String) {
        self.app = app
        self.version = version
        let env = ProcessInfo.processInfo.environment["UTHEME_HOME"]
        let root = (env?.isEmpty == false) ? URL(fileURLWithPath: env!) : FileManager.default.homeDirectoryForCurrentUser
        dataDir = root.appendingPathComponent(".local/share/utheme", isDirectory: true)
        current = dataDir.appendingPathComponent("current")
        clientsDir = root.appendingPathComponent(".local/state/utheme/clients", isDirectory: true)
    }

    private var heartbeat: URL { clientsDir.appendingPathComponent("\(app)-\(getpid()).json") }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        source?.cancel()
        source = nil
        removeHeartbeat()
    }

    private func watch() {
        guard source == nil else { return }
        let fd = Darwin.open(dataDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                          queue: .main)
        s.setEventHandler { [weak self, weak s] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let s, !s.data.intersection([.rename, .delete]).isEmpty {
                    s.cancel()
                    self.source = nil   // the folder itself went away; the 1 s poll re-watches
                }
                self.check()
            }
        }
        s.setCancelHandler { Darwin.close(fd) }
        s.resume()
        source = s
    }

    private func resolvedTarget() -> String? {
        guard let p = realpath(current.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    private func check() {
        watch()
        let target = resolvedTarget()
        if case .some(let last) = lastTarget, last == target { return }
        lastTarget = .some(target)
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.load(target) } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func load(_ target: String?) {
        guard let target else {
            // utheme not installed, or uninstalled: our own colours, no heartbeat.
            removeHeartbeat()
            applied = nil
            onChange?(nil)
            return
        }
        let dir = URL(fileURLWithPath: target, isDirectory: true)
        do {
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("palette.json")))
            guard let obj = raw as? [String: Any] else { throw Failure("palette.json unreadable") }
            var values: [String: String] = [:]
            for (k, v) in obj { if let s = v as? String { values[k] = s.lowercased() } }
            for k in Self.needs where NSColor(hex: values[k] ?? "") == nil {
                throw Failure("palette.json has no \(k)")
            }
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("theme.json"))))
                as? [String: Any] ?? [:]
            let generation = (meta["generation"] as? String) ?? dir.lastPathComponent
            let mode = (meta["mode"] as? String) ?? values["mode"] ?? "dark"
            applied = generation
            onChange?(Palette(values: values, mode: mode, generation: generation))
            writeHeartbeat(error: nil)
        } catch {
            // Keep the colours we have (or fall back if we never had any).
            if applied == nil { onChange?(nil) }
            writeHeartbeat(error: (error as? Failure)?.message ?? "palette.json unreadable")
        }
    }

    private func writeHeartbeat(error: String?) {
        var obj: [String: Any] = ["protocol": 1, "app": app, "version": version, "pid": Int(getpid()),
                                  "generation": applied ?? NSNull()]
        if let error { obj["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: clientsDir, withIntermediateDirectories: true)
        let tmp = clientsDir.appendingPathComponent(heartbeat.lastPathComponent + ".tmp")
        do {
            try data.write(to: tmp)
            Darwin.rename(tmp.path, heartbeat.path)
        } catch {}
    }

    private func removeHeartbeat() {
        try? FileManager.default.removeItem(at: heartbeat)
    }

    private struct Failure: Error {
        let message: String
        init(_ m: String) { message = m }
    }
}

extension NSColor {
    /// `#rrggbb` (case-insensitive), as utheme writes colours.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
