import CryptoKit
import Foundation
import PhotoLabCore

/// What survives a restart: the side-panel settings, the output folder, the sources and the user's presets. One
/// small JSON file in `~/Library/Application Support/Photo_Lab/` (private folder, file mode 0600, written
/// atomically). Everything read back is validated: a hand-edited or damaged file can only fall back to defaults,
/// never crash or inject values.
struct SavedState {
    static let maxBytes = 2_000_000
    static let maxFolders = 30
    static let maxImported = 2000

    var settings = Settings()
    var outputDir: String?
    var existingFiles = ExistingFiles.ask
    var folders: [String] = []
    var imported: [String] = []
    var view = "all"
    var appearance = "light"                      // light | dark | system
    var thumbHeight = 100.0                       // height of a thumbnail in the strip, 56...180
    var presets: [String: [String: Any]] = [:]

    static var fileURL: URL {
        let base: URL
        if let custom = ProcessInfo.processInfo.environment["PHOTOLAB_STATE_DIR"], !custom.isEmpty {
            base = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photo_Lab", isDirectory: true)
        }
        return base.appendingPathComponent("settings.json")
    }

    static func paths(_ v: Any?, max: Int) -> [String] {
        ((v as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty && $0.count <= 4096 }
            .prefix(max).map { $0 }
    }

    static func load() -> SavedState {
        var st = stat()
        let url = fileURL
        guard stat(url.path, &st) == 0, st.st_size > 0, Int(st.st_size) <= maxBytes,
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return SavedState() }
        var out = SavedState()
        out.settings = Settings(json: obj["settings"] as? [String: Any] ?? [:])
        if let p = obj["output_dir"] as? String, !p.isEmpty, p.count <= 4096 { out.outputDir = p }
        if let e = obj["existing_files"] as? String, let v = ExistingFiles(rawValue: e) { out.existingFiles = v }
        out.folders = paths(obj["folders"] ?? obj["sources"], max: maxFolders)
        out.imported = paths(obj["imported"], max: maxImported)
        if let v = obj["view"] as? String, v.count <= 4100 { out.view = v }
        if let a = obj["appearance"] as? String, ["light", "dark", "system"].contains(a) { out.appearance = a }
        if let h = obj["thumb_h"] as? NSNumber, !(obj["thumb_h"] is Bool), h.doubleValue.isFinite {
            out.thumbHeight = min(180, max(56, h.doubleValue))
        }
        if let p = obj["presets"] as? [String: Any] {
            for (name, v) in p.prefix(Presets.maxUser) {
                let clean = Text.clean(name, maxLength: 30)
                if !clean.isEmpty, !Presets.builtinNames.contains(clean), let d = v as? [String: Any] {
                    out.presets[clean] = Settings(json: d).json            // re-validated now, stored normalised
                }
            }
        }
        return out
    }

    func save() {
        let fm = FileManager.default
        let url = SavedState.fileURL
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var payload: [String: Any] = ["format": "photolab-swift", "version": 2, "settings": settings.json,
                                          "folders": folders, "imported": imported, "view": view, "appearance": appearance, "thumb_h": thumbHeight,
                                          "presets": presets]
            if let outputDir { payload["output_dir"] = outputDir }
            payload["existing_files"] = existingFiles.rawValue
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let tmp = dir.appendingPathComponent(".settings_\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp) }
        } catch {
            // settings are a convenience: a write problem must never get in the way of the app
        }
    }
}

/// The key of the source IDs written into outputs (`OutputSignature.sourceID`). Losing it means earlier outputs
/// are no longer recognised as their photos' own (new exports then get numbers; nothing is overwritten), so it
/// lives in a file of its own next to the settings: made once with O_EXCL (mode 0600), and never replaced. When
/// the file is there but cannot be read, this run uses a key of its own and leaves the file alone.
enum SourceKeyStore {
    static var fileURL: URL { SavedState.fileURL.deletingLastPathComponent().appendingPathComponent("source.key") }

    /// The key, and whether it is the one kept on disk (false: a key for this run only; the app says so).
    /// A new key file appears in one step (written to a temp file, then linked in place, which fails if one is
    /// there already), so it is either missing or complete, never half written.
    static func load() -> (key: Data, kept: Bool) {
        let url = fileURL
        if let key = readKey(url) { return (key, true) }
        var st = stat()
        let missing = lstat(url.path, &st) != 0 && errno == ENOENT
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard missing else { return (fresh, false) }              // there but unusable: never overwrite it
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".source_\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return (fresh, false) }
        let wrote = fresh.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) } == fresh.count && fsync(fd) == 0
        close(fd)
        defer { unlink(tmp.path) }
        guard wrote else { return (fresh, false) }
        if link(tmp.path, url.path) == 0 { return (fresh, true) }
        return readKey(url).map { ($0, true) } ?? (fresh, false)     // another instance made one just now?
    }

    /// The key file, if it is a regular file of this user, not readable by others, of 32 bytes. Opened without
    /// following a symlink and checked on the open file itself.
    private static func readKey(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size == 32, st.st_uid == getuid(),
              st.st_mode & 0o077 == 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 32)
        guard Darwin.read(fd, &buf, 32) == 32 else { return nil }
        return Data(buf)
    }
}
