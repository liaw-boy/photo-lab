import PhotoLabCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var advancedOpen = false
    @State private var showSources = false
    @State private var showSavePreset = false
    @State private var showDeletePreset = false
    @State private var showReplacePreset = false
    @State private var presetNameInput = ""
    @State private var presetError: String?
    @GestureState private var pinch = 1.0   // resets by itself when a pinch is cancelled (menus, panels)
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { settingsPanel.padding(.horizontal, Paper.gap + 2).padding(.vertical, Paper.gap) }
                .defaultScrollAnchor(.top)
                .frame(width: 340)
                .background(Paper.bg)
            VStack(spacing: 0) {
                previewArea
                splitter
                actionBar
                thumbStrip
            }
            .background(Paper.bg)
        }
        .frame(minWidth: 1100, minHeight: 700)
        .toggleStyle(PaperCheckboxStyle())
        .sheet(isPresented: $showSources) { SourceManagerView(model: model) }
        .alert("儲存預設", isPresented: $showSavePreset) {
            TextField("預設名稱（最多 30 字）", text: $presetNameInput)
            Button("儲存") {
                let r = model.savePreset(named: presetNameInput, overwrite: false)
                if r == "exists" { showReplacePreset = true } else if let r { presetError = r }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("覆蓋確認", isPresented: $showReplacePreset) {
            Button("覆蓋") { _ = model.savePreset(named: presetNameInput, overwrite: true) }
            Button("取消", role: .cancel) {}
        } message: { Text("已有名為「\(presetNameInput)」的預設，要覆蓋嗎？") }
        .alert("刪除預設", isPresented: $showDeletePreset) {
            Button("刪除", role: .destructive) { model.deletePreset(model.presetName) }
            Button("取消", role: .cancel) {}
        } message: { Text("要刪除預設「\(model.presetName)」嗎？") }
        .alert("來源金鑰", isPresented: Binding(get: { model.startupWarning != nil },
                                                set: { if !$0 { model.startupWarning = nil } })) {
            Button("好") {}
        } message: { Text(model.startupWarning ?? "") }
        .alert("無法儲存", isPresented: Binding(get: { presetError != nil }, set: { if !$0 { presetError = nil } })) {
            Button("好") {}
        } message: { Text(presetError ?? "") }
        .alert("輸出檔已存在",
               isPresented: Binding(get: { model.overwritePrompt != nil },
                                    set: { if !$0 { model.overwritePrompt = nil } }),
               presenting: model.overwritePrompt) { _ in
            Button("自動改名") { model.resolveOverwrite(.rename) }
            Button("覆蓋", role: .destructive) { model.resolveOverwrite(.overwrite) }
            Button("略過（只匯出新的）") { model.resolveOverwrite(.skip) }
            Button("取消", role: .cancel) { model.resolveOverwrite(nil) }
        } message: { p in Text(overwriteMessage(p)) }
    }

    private func overwriteMessage(_ p: OverwritePrompt) -> String {
        var t = "有 \(p.existing) 張照片在輸出資料夾裡已有上次的輸出。"
        t += p.different > 0 ? "其中 \(p.different) 張是用不同的設定做的，或沒有完整寫完。" : "它們的設定與現在相同。"
        if p.numbered > 0 { t += "\n另有 \(p.numbered) 張的檔名已被其他檔案使用，會存成 -2、-3…（不會蓋掉它們）。" }
        if p.legacy > 0 { t += "\n其中 \(p.legacy) 張是 1.2 以前的輸出，只能依檔名判斷是否為同一張照片。" }
        return t + "\n要自動改名（另存為 -2、-3…）、覆蓋，還是略過這些照片上次的輸出？"
    }

    // MARK: left panel

    private var layoutUsesFields: Bool { ["classic3", "center1", "center2", "split"].contains(model.settings.layout) }
    /// The one-click look that matches the current layout (nil for 自訂樣式).
    private var activeLook: String? {
        switch model.settings.layout {
        case "classic3": return "經典"
        case "center1": return "簡約置中"
        case "center2": return "完整資訊"
        case "split": return "左右分開"
        case "logo": return "只放 logo"
        case "custom":
            let hero = FooterStyle.sanitize(Presets.heroStyle)
            return model.settings.style == hero ? "logo 機型" : nil
        default: return nil
        }
    }
    private var usesExposure: Bool { model.settings.layout != "logo" }

    private var settingsPanel: some View {
        VStack(spacing: Paper.gap) {
            HStack(spacing: 10) {
                if let icon = model.headerIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Photo_Lab").font(.system(size: 20, weight: .bold))
                    Text(AppPaths.version.isEmpty ? "" : "版本 \(AppPaths.version)").font(.system(size: 11)).foregroundStyle(Paper.muted)
                }
                Spacer()
                if Updater.shared.isAvailable {
                    let newVersion = Updater.shared.newVersion
                    Button(newVersion.map { "有新版本 \($0)" } ?? "檢查更新") { Updater.shared.checkForUpdates() }
                        .buttonStyle(PaperButtonStyle(filled: newVersion != nil, compact: true))
                        .disabled(!Updater.shared.canCheck)
                        .help(newVersion == nil ? "到 GitHub 檢查是否有新版本" : "按下查看更新內容並安裝")
                }
            }
            .padding(.bottom, 0)
            presetCard
            sourceCard
            frameCard
            footerCard
        }
    }

    private var presetCard: some View {
        PaperCard(title: "預設組合", symbol: "square.grid.2x2") {
            HStack(spacing: 6) {
                Menu {
                    Section("內建") {
                        ForEach(Presets.builtinNames, id: \.self) { n in Button(n) { model.applyPreset(n) } }
                    }
                    if !model.presets.isEmpty {
                        Section("我的預設") {
                            ForEach(model.presets.keys.sorted(), id: \.self) { n in Button(n) { model.applyPreset(n) } }
                        }
                    }
                } label: {
                    Text(model.presetName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button).buttonStyle(PaperButtonStyle(compact: true))
                Button("儲存") { presetNameInput = ""; showSavePreset = true }
                    .buttonStyle(PaperButtonStyle(compact: true))
                Button("刪除") { showDeletePreset = true }
                    .buttonStyle(PaperButtonStyle(compact: true))
                    .disabled(model.presets[model.presetName] == nil)
            }
        }
    }

    private var sourceCard: some View {
        PaperCard(title: "來源與輸出", symbol: "tray.and.arrow.down") {
            Menu {
                Button("全部照片") { model.view = .all }
                ForEach(model.folders, id: \.self) { f in Button(f.lastPathComponent) { model.view = .folder(f) } }
                if !model.imported.isEmpty { Button("已匯入") { model.view = .imported } }
                Divider()
                Button("加入資料夾…") { model.chooseFolder() }
                Button("匯入照片…") { model.choosePhotos() }
                Button("管理來源…") { showSources = true }
            } label: {
                Text(model.folders.isEmpty && model.imported.isEmpty ? "還沒有來源，按這裡加入" : model.viewLabel)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button).buttonStyle(PaperButtonStyle())
            HStack {
                Text("輸出到").font(.system(size: 12))
                Text(model.outputDir?.lastPathComponent ?? "").lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: Paper.controlHeight)
                    .background(Paper.fill, in: RoundedRectangle(cornerRadius: Paper.controlRadius))
                Button("選擇") { model.chooseOutput() }.buttonStyle(PaperButtonStyle())
                    .disabled(model.exporting || model.planning)
            }
            HStack {
                Text("既有檔案").font(.system(size: 12))
                Menu {
                    ForEach(ExistingFiles.allCases, id: \.self) { e in
                        Button(e.label) { model.existingFiles = e }
                    }
                } label: {
                    Text(model.existingFiles.label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button).buttonStyle(PaperButtonStyle())
                .disabled(model.exporting || model.planning)
                .help("照片在輸出資料夾已有上次的輸出時怎麼做。1.2 起的輸出記得自己的來源照片：別張照片的同名檔案不會被覆蓋，新的輸出改用 -2、-3…（1.2 以前的輸出只能依檔名判斷）")
            }
        }
    }

    private var frameCard: some View {
        PaperCard(title: "邊框", symbol: "square.dashed") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Settings.ratios, id: \.value) { r in
                    RatioTile(label: r.label, value: r.value, selected: model.settings.ratio == r.value) {
                        model.settings.ratio = r.value
                    }
                }
            }
            HStack {
                Text("粗細")
                Spacer()
                Text("\(Int(model.settings.thickness))").monospacedDigit()
                    .frame(width: 40, height: 24).background(Paper.fill, in: RoundedRectangle(cornerRadius: 8))
            }
            Slider(value: whole(\.thickness), in: 0...50).tint(Paper.ink)
            PaperSegmented(options: [("白底", false), ("模糊", true)], selection: $model.settings.blurBackground)
            Toggle("圓角", isOn: $model.settings.rounded).toggleStyle(PaperSwitchStyle())
            if model.settings.rounded {
                HStack {
                    Text("弧度").font(.system(size: 12))
                    Slider(value: whole(\.cornerPerMille), in: 1...60).tint(Paper.ink)
                    Text("\(Int(model.settings.cornerPerMille))").monospacedDigit().frame(width: 28)
                }
            }
        }
    }

    private var footerCard: some View {
        PaperCard(title: "相機資訊", symbol: "camera") {
            Toggle("在底部顯示相機參數", isOn: $model.settings.footerOn).toggleStyle(PaperSwitchStyle())
            if model.settings.footerOn {
                FlowLayout(spacing: 6) {
                    ForEach(Presets.footerLooks, id: \.name) { look in
                        Button(look.name) { model.applyLook(look.name) }
                            .buttonStyle(PaperButtonStyle(filled: activeLook == look.name, compact: true))
                    }
                }
                Button { openWindow(id: "style-editor") } label: {
                    Label("編輯樣式…", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperButtonStyle(filled: activeLook == nil, compact: true))
                fieldToggles.disabled(!layoutUsesFields)
                TextField("自訂文字（例如地點）", text: $model.settings.customText).textFieldStyle(.roundedBorder)
                PaperMenu(title: "日期格式", options: Settings.dateFormats, selection: $model.settings.dateFormat)
                    .disabled(model.settings.layout == "logo")
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { advancedOpen.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                            Text(advancedOpen ? "進階" : "進階（字體、顏色、大小…）")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())      // the whole row is the hit area, not only the arrow
                    }
                    .buttonStyle(.plain)
                    if advancedOpen { advancedControls }
                }
            }
        }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaperMenu(title: "字體", options: model.fonts.map { (label: $0.label, value: $0.key) },
                      selection: $model.settings.font)
            HStack {
                PaperMenu(title: "文字顏色", options: Settings.colors, selection: $model.settings.colorChoice)
                if model.settings.colorChoice == "custom" {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: model.settings.customColor) },
                        set: { model.settings.customColor = $0.hexString }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            scaleSlider("文字大小", \.textScale, 0.5...2.0)
            scaleSlider("logo 大小", \.logoScale, 0.4...2.5)
            scaleSlider("資訊列高度", \.heightScale, 0.6...2.5)
            if usesExposure {
                PaperMenu(title: "順序", options: Settings.exposureOrders, selection: $model.settings.exposureOrder)
            }
            Button("重設進階選項") {
                var s = model.settings
                s.font = "auto"; s.colorChoice = "auto"; s.textScale = 1; s.logoScale = 1; s.heightScale = 1
                s.exposureItems = ["aperture", "shutter", "iso"]; s.exposureOrder = "std"
                model.settings = s
            }
            .buttonStyle(PaperButtonStyle(compact: true))
        }
    }

    private func scaleSlider(_ title: String, _ key: WritableKeyPath<Settings, Double>,
                             _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { model.settings[keyPath: key] },
                                  set: { model.settings[keyPath: key] = ($0 * 20).rounded() / 20 }), in: range)
                .tint(Paper.ink)
            Text("\(Int((model.settings[keyPath: key] * 100).rounded()))%").monospacedDigit()
                .font(.system(size: 12)).frame(width: 44, alignment: .trailing)
        }
    }

    /// A slider value that snaps to whole numbers without drawing a tick mark for every step.
    private func whole(_ key: WritableKeyPath<Settings, Double>) -> Binding<Double> {
        Binding(get: { model.settings[keyPath: key] }, set: { model.settings[keyPath: key] = $0.rounded() })
    }

    /// 機型 / 鏡頭 / 焦距 / 參數 / 日期. 焦距 and 參數 are the two halves of the exposure text.
    private var fieldToggles: some View {
        func plain(_ key: String, _ label: String) -> some View {
            Toggle(label, isOn: Binding(
                get: { model.settings.fields.contains(key) },
                set: { on in
                    if on { model.settings.fields.insert(key) } else { model.settings.fields.remove(key) }
                }))
        }
        let triple = ["aperture", "shutter", "iso"]
        let focal = Binding<Bool>(
            get: { model.settings.fields.contains("exposure") && model.settings.exposureItems.contains("focal") },
            set: { on in
                var s = model.settings
                s.exposureItems.removeAll { $0 == "focal" }
                if on { s.exposureItems.append("focal"); s.fields.insert("exposure") }
                if s.exposureItems.isEmpty { s.fields.remove("exposure") }
                model.settings = s
            })
        let params = Binding<Bool>(
            get: { model.settings.fields.contains("exposure") && model.settings.exposureItems.contains { triple.contains($0) } },
            set: { on in
                var s = model.settings
                s.exposureItems.removeAll { triple.contains($0) }
                if on { s.exposureItems += triple; s.fields.insert("exposure") }
                if s.exposureItems.isEmpty { s.fields.remove("exposure") }
                model.settings = s
            })
        return HStack {
            plain("camera", "機型")
            plain("lens", "鏡頭")
            Toggle("焦距", isOn: focal)
            Toggle("參數", isOn: params)
            plain("date", "日期")
        }
        .toggleStyle(PaperCheckboxStyle())
    }

    // MARK: preview

    private var previewArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: Paper.radius).fill(Color(white: 0.85))
                if let img = model.preview {
                    ScrollView([.horizontal, .vertical], showsIndicators: model.zoom > 1.01) {
                        Image(nsImage: img).interpolation(.high).antialiased(true)
                            .frame(minWidth: geo.size.width - 4, minHeight: geo.size.height - 4)
                            .scaleEffect(pinch)
                    }
                    .defaultScrollAnchor(.center)
                    .gesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { v in
                            model.zoom = min(AppModel.zoomRange.upperBound,
                                             max(AppModel.zoomRange.lowerBound, model.zoom * v.magnification))
                        })
                    .onTapGesture(count: 2) { model.zoom = model.zoom > 1.01 ? 1 : 2.5 }
                    .clipShape(RoundedRectangle(cornerRadius: Paper.radius))
                } else {
                    Text(model.previewNote).foregroundStyle(Paper.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                zoomBar.padding(10)
            }
            .onAppear { updateTarget(geo.size) }
            .onChange(of: geo.size) { _, new in updateTarget(new) }
        }
        .padding(.horizontal, Paper.gap + 2)
        .padding(.top, Paper.gap)
        .padding(.bottom, Paper.inner)
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Button { model.zoom = max(1, model.zoom / 1.25) } label: { Image(systemName: "minus") }
                .buttonStyle(PaperButtonStyle(compact: true))
            Slider(value: Binding(get: { log2(model.zoom) },
                                  set: { model.zoom = min(6, max(1, pow(2, $0))) }), in: 0...log2(6))
                .frame(width: 90).tint(Paper.ink)
            Button { model.zoom = min(6, model.zoom * 1.25) } label: { Image(systemName: "plus") }
                .buttonStyle(PaperButtonStyle(compact: true))
            Text("\(Int((model.zoom * 100).rounded()))%").font(.system(size: 12)).monospacedDigit().frame(width: 44)
            Button("適合視窗") { model.zoom = 1 }.buttonStyle(PaperButtonStyle(compact: true))
        }
        .padding(8)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: Paper.radius))
        .overlay(RoundedRectangle(cornerRadius: Paper.radius).stroke(Paper.ink, lineWidth: Paper.thin))
    }

    /// The preview is rendered to exactly the pixels it occupies on screen, so it is not resampled again.
    private func updateTarget(_ size: CGSize) {
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        let w = max(200, size.width - 8) * scale, h = max(200, size.height - 8) * scale
        model.previewTarget = CGSize(width: w.rounded(), height: h.rounded())
    }

    // MARK: actions + strip

    private var actionBar: some View {
        HStack(spacing: Paper.inner) {
            Text(model.photos.isEmpty ? "尚未加入來源" : "\(model.photos.count) 張，已勾選 \(model.checkedCount) 張")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            Text(model.status).font(.system(size: 12)).foregroundStyle(Paper.muted)
            if model.exporting {
                ProgressView(value: model.progress).frame(width: 120).tint(Paper.ink)
                Button("停止") { model.stopExport() }.buttonStyle(PaperButtonStyle(compact: true))
            }
            Button(model.allChecked ? "取消全選" : "全選") { model.toggleAll() }
                .buttonStyle(PaperButtonStyle(compact: true)).disabled(model.photos.isEmpty)
            Button("重設") { model.reset() }.buttonStyle(PaperButtonStyle(compact: true))
            Button { model.export() } label: { Label("匯出勾選的照片", systemImage: "square.and.arrow.up") }
                .buttonStyle(PaperButtonStyle(filled: true))
                .disabled(model.exporting || model.planning || model.photos.isEmpty)
        }
        .padding(.horizontal, Paper.gap + 2)
        .padding(.bottom, 2)
    }

    /// Drag this bar up / down to resize the strip; the thumbnails scale with it (56...180 pt high, remembered).
    private var splitter: some View {
        Color.clear
            .frame(height: 10)
            .overlay(Capsule().fill(Paper.ink.opacity(0.3)).frame(width: 44, height: 4))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    if dragStart == nil { dragStart = model.thumbHeight }
                    let h = (dragStart ?? model.thumbHeight) - v.translation.height
                    model.thumbHeight = min(AppModel.thumbRange.upperBound, max(AppModel.thumbRange.lowerBound, h.rounded()))
                }
                .onEnded { _ in dragStart = nil })
    }

    private var thumbStrip: some View {
        let h = model.thumbHeight
        return ScrollView(.horizontal) {
            LazyHStack(spacing: Paper.inner) {
                ForEach($model.photos) { $item in
                    ThumbTile(item: $item, isSelected: model.selected == item.url, height: h) {
                        model.selected = item.url
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
        }
        .frame(height: h + 12 + 20 + 6)                          // picture + ring room + file name + a little air
        .padding(.horizontal, Paper.gap + 2)
        .padding(.bottom, Paper.inner)
    }
}

struct ThumbTile: View {
    @Binding var item: PhotoItem
    let isSelected: Bool
    let height: CGFloat
    let select: () -> Void
    private var width: CGFloat { (height * 1.5).rounded() }

    var body: some View {
        VStack(spacing: 2) {
            thumbnail
                .padding(6)                                    // room for the selection ring around the picture
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Paper.ink, lineWidth: 2)
                        .opacity(isSelected ? 1 : 0)
                )
            Text(item.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(width: width)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let t = item.thumb { Image(nsImage: t).resizable().scaledToFill() }
                else { Rectangle().fill(Paper.fill) }
            }
            .frame(width: width, height: height)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Paper.ink.opacity(0.35), lineWidth: 1))
            Toggle("", isOn: $item.checked).toggleStyle(PaperCheckboxStyle()).labelsHidden().padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            if item.mark != .none {
                Text(markText).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Paper.ink, in: Capsule())
                    .padding(6)
            }
        }
    }

    private var markText: String {
        switch item.mark {
        case .done: return "完成"
        case .failed: return "失敗"
        case .skipped: return "略過"
        case .none: return ""
        }
    }
}
