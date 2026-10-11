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
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let tmp = dir.appendingPathComponent(".settings_\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp) }
        } catch {
            // settings are a convenience: a write problem must never get in the way of the app
        }
    }
}
