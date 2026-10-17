import AppKit
import Foundation
import Observation
import PhotoLabCore

struct PhotoItem: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var checked = true
    var thumb: NSImage?
    var mark: Mark = .none

    enum Mark { case none, done, failed, skipped }
}

/// Which photos the strip shows.
enum SourceView: Equatable {
    case all
    case imported
    case folder(URL)

    var key: String {
        switch self {
        case .all: return "all"
        case .imported: return "imported"
        case .folder(let u): return "folder:" + u.path
        }
    }

    init(key: String) {
        if key == "imported" { self = .imported }
        else if key.hasPrefix("folder:") { self = .folder(URL(fileURLWithPath: String(key.dropFirst(7)))) }
        else { self = .all }
    }
}

struct OverwritePrompt: Identifiable {
    let id = UUID()
    let existing: Int
    let different: Int
}

/// Where logos/ and fonts/ are: PHOTOLAB_ROOT, the repository this binary was built in, or Application Support.
enum AppPaths {
    /// The app icon picture: inside the .app bundle, or assets/ of the repository during development.
    static func iconURL() -> URL {
        if let u = Bundle.main.url(forResource: "icon_1024", withExtension: "png") { return u }
        return resources().logosDir.deletingLastPathComponent().appendingPathComponent("assets/icon_1024.png")
    }

    /// "1.0.0": from the bundle's Info.plist, or the VERSION file of the repository.
    static var version: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty { return v }
        let url = resources().logosDir.deletingLastPathComponent().appendingPathComponent("VERSION")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.count <= 20 && v.allSatisfy({ $0.isNumber || $0 == "." }) ? v : ""
    }

    static func resources() -> Resources {
        let fm = FileManager.default
        var roots: [URL] = []
        // a packaged app uses only what it carries (or Application Support): no environment / parent folder lookup
        let packaged = Bundle.main.bundlePath.hasSuffix(".app")
        if !packaged, let env = ProcessInfo.processInfo.environment["PHOTOLAB_ROOT"] {
            roots.append(URL(fileURLWithPath: env))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<(packaged ? 0 : 8) {
            roots.append(dir)
            dir.deleteLastPathComponent()
        }
        for r in roots where fm.fileExists(atPath: r.appendingPathComponent("logos").path)
            && fm.fileExists(atPath: r.appendingPathComponent("python").path) {
            return Resources(logosDir: r.appendingPathComponent("logos"), fontsDir: r.appendingPathComponent("fonts"))
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo_Lab")
        // the user's own logos win; otherwise a personal build carries the ones that were next to it (package.sh)
        let supportLogos = (try? fm.contentsOfDirectory(atPath: support.appendingPathComponent("logos").path)) ?? []
        if supportLogos.isEmpty, let res = Bundle.main.resourceURL,
           fm.fileExists(atPath: res.appendingPathComponent("logos").path) {
            return Resources(logosDir: res.appendingPathComponent("logos"), fontsDir: res.appendingPathComponent("fonts"))
        }
        return Resources(logosDir: support.appendingPathComponent("logos"),
                         fontsDir: support.appendingPathComponent("fonts"))
    }
}

@MainActor
@Observable
final class AppModel {
    static let maxPhotos = 2000

    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.layout != "custom" { styleBase = nil }
            schedulePreview(); scheduleSave()
        }
    }
    var presets: [String: [String: Any]] = [:] { didSet { scheduleSave() } }
    var presetName = Presets.placeholder
    /// The one-click look a custom style was started from (shown next to its name; cleared when a layout is picked).
    var styleBase: String?
    var folders: [URL] = [] { didSet { scheduleSave() } }
    var imported: [URL] = [] { didSet { scheduleSave() } }
    var view: SourceView = .all { didSet { if view != oldValue { scheduleSave(); reloadPhotos() } } }
    var folderCounts: [URL: Int] = [:]
    var appearance = "light" { didSet { if appearance != oldValue { scheduleSave() } } }
    /// Height of a thumbnail in the strip (points); the strip and the tiles follow it.
    var thumbHeight = 100.0 { didSet { if thumbHeight != oldValue { scheduleSave() } } }
    static let thumbRange = 56.0...180.0
    var photos: [PhotoItem] = []
    var selected: URL? { didSet { if selected != oldValue { loadPreviewSource() } } }
    var outputDir: URL? { didSet { if outputDir != oldValue { scheduleSave() } } }
    var preview: NSImage?
    var previewNote = "還沒有照片：按左邊的「選擇」加入資料夾或照片"
    var status = "待機中"
    var exporting = false
    var progress = 0.0
    var overwritePrompt: OverwritePrompt?
    var fonts: [(key: String, label: String)] = []
    /// Pixels available to the preview (view size x screen scale); the render is reduced to fit it exactly.
    var previewTarget = CGSize(width: 1400, height: 1400) { didSet { if previewTarget != oldValue { requestPreview() } } }
    /// 1 = the whole picture fits the window; larger values render more pixels and let the view scroll.
    var zoom = 1.0 { didSet { if zoom != oldValue { requestPreview() } } }
    static let zoomRange = 1.0...6.0
    private var previewSourceEdge = 0

    private var saveTask: Task<Void, Never>?
    private var previewSource: CGImage?
    private var previewInfo = PhotoInfo.sample
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var checkedState: [URL: Bool] = [:]
    let resources = AppPaths.resources()

    /// The app's icon (the same picture the Python version uses), found next to the logos / fonts folders.
    let appIcon: NSImage? = NSImage(contentsOf: AppPaths.iconURL())

    /// The same picture with its transparent margin trimmed (the Dock icon keeps the margin macOS expects), so the
    /// rounded square fills its box in the side panel.
    @ObservationIgnored let headerIcon: NSImage? = {
        guard let icon = NSImage(contentsOf: AppPaths.iconURL()),
              let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let m = Int(Double(cg.width) * 0.125)   // margin (9.5 %) + the artwork's own corner, so only the square body is left
        let rect = CGRect(x: m, y: m, width: cg.width - 2 * m, height: cg.height - 2 * m)
        guard let cropped = cg.cropping(to: rect) else { return icon }
        return NSImage(cgImage: cropped, size: NSSize(width: 40, height: 40))
    }()

    var checkedCount: Int { photos.filter(\.checked).count }
    var allChecked: Bool { !photos.isEmpty && photos.allSatisfy(\.checked) }
    var viewLabel: String {
        switch view {
        case .all: return "全部照片"
        case .imported: return "已匯入"
        case .folder(let u): return u.lastPathComponent
        }
    }

    init() {
        let saved = SavedState.load()
        settings = saved.settings
        presets = saved.presets
        if let p = saved.outputDir { outputDir = URL(fileURLWithPath: p, isDirectory: true) }
        folders = saved.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        imported = saved.imported.map { URL(fileURLWithPath: $0) }
        view = SourceView(key: saved.view)
        appearance = saved.appearance
        thumbHeight = saved.thumbHeight
        fonts = FooterSpec.availableFonts(resources: resources)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        Task.detached(priority: .background) { ThumbCache.prune() }
    }

    // MARK: persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        var st = SavedState()
        st.settings = settings
        st.outputDir = outputDir?.path
        st.folders = folders.map(\.path)
        st.imported = imported.map(\.path)
        st.view = view.key
        st.appearance = appearance
        st.thumbHeight = thumbHeight
        st.presets = presets
        st.save()
    }

    // MARK: sources

    /// Folders and photos from the open panel, drag & drop or the command line.
    func add(urls: [URL]) {
        var lastFolder: URL?
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let f = u.standardizedFileURL
                if !folders.contains(where: { $0.standardizedFileURL == f }), folders.count < SavedState.maxFolders {
                    folders.append(f)
                }
                lastFolder = f
            } else if Files.extensions.contains(u.pathExtension.lowercased()), !u.lastPathComponent.hasPrefix(".") {
                files.append(u.standardizedFileURL)
            }
        }
        if !files.isEmpty {
            var set = Set(imported)
            for f in files where set.insert(f).inserted && imported.count < SavedState.maxImported { imported.append(f) }
        }
        if let lastFolder { view = .folder(lastFolder); reloadPhotos() }
        else if !files.isEmpty { view = .imported; reloadPhotos() }
        refreshCounts()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "加入資料夾"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.title = "匯入照片"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .png, .tiff]
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        folderCounts[url] = nil
        if view == .folder(url) { view = .all }
        else { reloadPhotos() }
    }

    func clearImported() {
        imported = []
        if view == .imported { view = .all } else { reloadPhotos() }
    }

    func clearMissing() {
        folders = folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        imported = imported.filter { FileManager.default.fileExists(atPath: $0.path) }
        refreshCounts()
        reloadPhotos()
    }

    func refreshCounts() {
        let list = folders
        Task.detached(priority: .utility) { [weak self] in
            var counts: [URL: Int] = [:]
            for f in list { counts[f] = Files.photos(in: f).count }
            guard let model = self else { return }
            await MainActor.run { model.folderCounts = counts }
        }
    }

    /// Lists the photos of the current view in the background, keeping the ticks of those already known.
    func reloadPhotos() {
        for p in photos { checkedState[p.url] = p.checked }
        let v = view, fs = folders, imp = imported
        listTask?.cancel()
        listTask = Task.detached(priority: .userInitiated) { [weak self] in
            var urls: [URL] = []
            switch v {
            case .all:
                for f in fs { urls += Files.photos(in: f) }
                urls += imp.filter { FileManager.default.fileExists(atPath: $0.path) }
            case .imported:
                urls = imp.filter { FileManager.default.fileExists(atPath: $0.path) }
            case .folder(let f):
                urls = Files.photos(in: f)
            }
            var seen = Set<URL>()
            urls = urls.filter { seen.insert($0.standardizedFileURL).inserted }.prefix(AppModel.maxPhotos).map { $0 }
            if Task.isCancelled { return }
            guard let model = self else { return }
            await MainActor.run { model.show(urls) }
        }
    }

    private func show(_ urls: [URL]) {
        photos = urls.map { u in
            var item = PhotoItem(url: u)
            item.checked = checkedState[u] ?? true
            return item
        }
        status = photos.isEmpty ? "這裡沒有可用的照片" : "已載入 \(photos.count) 張"
        if selected == nil || !photos.contains(where: { $0.url == selected }) { selected = photos.first?.url }
        if photos.isEmpty { preview = nil; previewSource = nil; previewNote = "這裡沒有 JPEG / PNG / TIFF 照片" }
        loadThumbs()
    }

    private func loadThumbs() {
        let urls = photos.map(\.url)
        Task.detached(priority: .utility) { [weak self] in
            for url in urls {
                guard let cg = ThumbCache.thumbnail(for: url, maxEdge: 360) else { continue }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                guard let model = self else { return }
                await MainActor.run {
                    guard let i = model.photos.firstIndex(where: { $0.url == url }) else { return }
                    model.photos[i].thumb = img
                }
            }
        }
    }

    func toggleAll() {
        let all = photos.allSatisfy(\.checked)
        for i in photos.indices { photos[i].checked = !all }
    }

    /// 重設: back to the plain look - a white border only (no rounded corners, no camera footer) - with every photo
    /// ticked again and the 完成 / 失敗 / 略過 marks cleared. Sources and the output folder stay.
    func reset() {
        settings = Settings()
        presetName = Presets.placeholder
        styleBase = nil
        for i in photos.indices { photos[i].checked = true; photos[i].mark = .none }
        checkedState = [:]
        zoom = 1
        status = "已重設：只加白邊"
    }

    // MARK: presets

    var presetNames: [String] { Presets.builtinNames + presets.keys.sorted() }

    func applyPreset(_ name: String) {
        presetName = name
        if let b = Presets.builtin.first(where: { $0.name == name }) {
            var s = settings
            Presets.applyBuiltin(b.values, to: &s)
            settings = s
        } else if let d = presets[name] {
            settings = Settings(json: d)
        }
        status = "已套用預設：\(name)"
    }

    /// Returns an error text, or nil when saved.
    func savePreset(named raw: String, overwrite: Bool) -> String? {
        let name = Text.clean(raw, maxLength: 30)
        if name.isEmpty { return "請輸入名稱" }
        if Presets.builtinNames.contains(name) { return "這是內建預設的名稱，請換一個" }
        if presets[name] != nil && !overwrite { return "exists" }
        if presets[name] == nil && presets.count >= Presets.maxUser { return "最多只能儲存 \(Presets.maxUser) 個自訂預設" }
        presets[name] = settings.json
        presetName = name
        status = "已儲存預設：\(name)"
        return nil
    }

    func deletePreset(_ name: String) {
        guard presets[name] != nil else { return }
        presets[name] = nil
        presetName = Presets.placeholder
    }

    func applyLook(_ name: String) {
        guard let look = Presets.footerLooks.first(where: { $0.name == name }) else { return }
        var s = settings
        Presets.applyLook(look.values, to: &s)
        settings = s
    }

    // MARK: style (the user-designed footer)

    /// The name of the style on screen: the built-in layout, or 自訂樣式 (with the look it started from).
    var styleName: String {
        guard settings.layout == "custom" else {
            return Settings.layouts.first { $0.value == settings.layout }?.label ?? "經典三欄"
        }
        if let base = styleBase { return "自訂樣式（從「\(base)」開始）" }
        return "自訂樣式"
    }

    /// Starts a custom style from one of the one-click looks.
    func startStyle(from look: String) {
        applyLook(look)
        makeCustom()
        styleBase = look
    }

    /// The style on screen right now, in the editor's model (a built-in layout is converted).
    var effectiveStyle: FooterStyle {
        if settings.layout == "custom" { return settings.style }
        var o = FooterStyle.LayoutOptions()
        o.fields = settings.fields
        o.divider = settings.divider
        o.mirror = settings.mirror
        o.main = settings.mainLens ? "lens" : "model"
        o.logoPos = settings.logoPos
        o.centerDivider = settings.centerDivider
        o.focal = settings.exposureItems.contains("focal")
        return FooterStyle.fromLayout(settings.layout, o)
    }

    /// Switches the footer to 自訂樣式, starting from what is shown now.
    func makeCustom() {
        guard settings.layout != "custom" || !settings.footerOn else { return }
        var s = settings
        s.style = effectiveStyle
        s.layout = "custom"
        s.footerOn = true
        settings = s
    }

    func editStyle(_ change: (inout FooterStyle) -> Void) {
        var st = effectiveStyle
        change(&st)
        var s = settings
        s.style = st
        s.layout = "custom"
        s.footerOn = true
        settings = s
    }

    // MARK: style files

    func exportStyle() {
        let panel = NSSavePanel()
        panel.title = "匯出樣式"
        panel.nameFieldStringValue = "我的樣式.igstyle.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload: [String: Any] = ["format": "ig-border-style", "version": 1, "name": "",
                                      "style": settings.style.json, "settings": [String: Any]()]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func importStyle() {
        let panel = NSOpenPanel()
        panel.title = "匯入樣式"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // read at most one byte more than allowed, so a file that grows after a size check cannot be read whole
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 200_001), !data.isEmpty, data.count <= 200_000,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["format"] as? String) == "ig-border-style" else {
            status = "這不是樣式檔"
            return
        }
        var s = settings
        s.style = FooterStyle.sanitize(obj["style"])
        s.layout = "custom"
        s.footerOn = true
        settings = s
    }

    // MARK: preview

    /// Pixels the current zoom needs, bounded so that a zoomed render stays reasonable in memory.
    private var neededEdge: Int {
        let t = previewTarget
        return min(6000, Int(max(t.width, t.height) * zoom))
    }

    /// The preview needs more (or fewer) source pixels when the window or the zoom changes.
    private func requestPreview() {
        let need = max(1800, min(6000, neededEdge * 5 / 4))
        if let url = selected, previewSource != nil, need > previewSourceEdge || need < previewSourceEdge / 2 {
            loadPreviewSource(edge: need, url: url)
        } else {
            schedulePreview()
        }
    }

    private func loadPreviewSource() { if let url = selected { loadPreviewSource(edge: max(1800, min(6000, neededEdge * 5 / 4)), url: url) } }

    private func loadPreviewSource(edge: Int, url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = try? Renderer.loadPreview(url: url, maxEdge: edge)
            let info = ExifReader.read(url: url)
            guard let model = self else { return }
            await MainActor.run {
                guard model.selected == url else { return }
                model.previewSource = img
                model.previewSourceEdge = edge
                model.previewInfo = info
                model.previewNote = img == nil ? "讀不到這張照片" : ""
                model.schedulePreview()
            }
        }
    }

    func schedulePreview() {
        previewTask?.cancel()
        guard let src = previewSource else { return }
        let s = settings, info = previewInfo, res = resources
        let target = CGSize(width: previewTarget.width * zoom, height: previewTarget.height * zoom)
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
            var footer: FooterSpec?
            if s.footerOn { footer = FooterSpec(options: s.footerOptions, info: info, resources: res) }
            guard var out = try? Renderer.render(src, options: s.renderOptions, footer: footer, resources: res),
                  !Task.isCancelled else { return }
            out = Renderer.fitted(out, into: target)        // reduced once, with a good filter, to the screen pixels
            let img = NSImage(cgImage: out, size: NSSize(width: Double(out.width) / scale,
                                                         height: Double(out.height) / scale))
            guard let model = self else { return }
            await MainActor.run { model.preview = img }
        }
    }

    /// The footer strip for the style editor: the photo on an even border, cropped to its bottom part.
    func renderStrip() async -> NSImage? {
        guard let src = previewSource else { return nil }
        var s = settings
        s.ratio = "even"
        s.footerOn = true
        let info = previewInfo, res = resources
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let footer = FooterSpec(options: s.footerOptions, info: info, resources: res)
            guard let full = try? Renderer.render(src, options: s.renderOptions, footer: footer, resources: res)
            else { return nil }
            let h = full.height
            let rect = CGRect(x: 0, y: Int(Double(h) * 0.66), width: full.width, height: h - Int(Double(h) * 0.66))
            guard let strip = full.cropping(to: rect) else { return nil }
            return NSImage(cgImage: strip, size: NSSize(width: strip.width, height: strip.height))
        }.value
    }

    // MARK: export

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "選擇輸出資料夾"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDir = url
    }

    /// Checks the rules, asks about files that already exist, then runs.
    func export() {
        guard !exporting else { return }
        let items = photos.filter(\.checked)
        guard !items.isEmpty else { status = "沒有勾選的照片"; return }
        if outputDir == nil { chooseOutput() }
        guard let out = outputDir else { return }
        for f in folders where Files.conflict(f, out) {
            status = "輸出資料夾不能和來源資料夾相同或互相包含"
            return
        }
        let s = settings
        var existing = 0, different = 0
        for item in items {
            let dst = out.appendingPathComponent(Files.outputName(for: item.url))
            guard FileManager.default.fileExists(atPath: dst.path) else { continue }
            existing += 1
            let sig = OutputSignature.make(source: item.url, settings: s.fingerprintSource)
            if OutputSignature.existing(at: dst) != sig { different += 1 }
        }
        if existing > 0 { overwritePrompt = OverwritePrompt(existing: existing, different: different); return }
        run(items: items, out: out, overwrite: false)
    }

    func resolveOverwrite(overwrite: Bool?) {
        overwritePrompt = nil
        guard let overwrite, let out = outputDir else { return }
        run(items: photos.filter(\.checked), out: out, overwrite: overwrite)
    }

    private func run(items: [PhotoItem], out: URL, overwrite: Bool) {
        exporting = true
        progress = 0
        for i in photos.indices where photos[i].checked { photos[i].mark = .none }
        let s = settings, res = resources
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            var done = 0, failed = 0, skipped = 0
            var reasons: [String: Int] = [:]
            for (n, item) in items.enumerated() {
                if Task.isCancelled { break }
                let dst = out.appendingPathComponent(Files.outputName(for: item.url))
                var mark = PhotoItem.Mark.done
                if !overwrite && FileManager.default.fileExists(atPath: dst.path) {
                    skipped += 1; mark = .skipped
                } else {
                    do {
                        let photo = try Renderer.load(url: item.url)
                        var footer: FooterSpec?
                        if s.footerOn {
                            footer = FooterSpec(options: s.footerOptions, info: ExifReader.read(url: item.url),
                                                resources: res)
                        }
                        let canvas = try Renderer.render(photo, options: s.renderOptions, footer: footer, resources: res)
                        let sig = OutputSignature.make(source: item.url, settings: s.fingerprintSource)
                        try Renderer.saveJPEG(canvas, to: dst, quality: s.renderOptions.quality, signature: sig,
                                              replace: overwrite)
                        done += 1
                    } catch RenderError.exists {
                        skipped += 1; mark = .skipped
                    } catch {
                        failed += 1; mark = .failed; reasons[(error as? RenderError)?.userMessage ?? "未知錯誤", default: 0] += 1
                    }
                }
                let p = Double(n + 1) / Double(items.count), m = mark
                guard let model = self else { return }
                await MainActor.run {
                    if let i = model.photos.firstIndex(where: { $0.url == item.url }) { model.photos[i].mark = m }
                    model.progress = p
                    model.status = "匯出中 \(n + 1) / \(items.count)"
                }
            }
            let (d, sk, f) = (done, skipped, failed)
            let why = reasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "、")
            guard let model = self else { return }
            await MainActor.run {
                model.exporting = false
                model.status = "完成 \(d) 張" + (sk > 0 ? "，略過 \(sk) 張（已存在）" : "")
                    + (f > 0 ? "，失敗 \(f) 張（\(why)）" : "")
            }
        }
    }

    func stopExport() { exportTask?.cancel() }
}
