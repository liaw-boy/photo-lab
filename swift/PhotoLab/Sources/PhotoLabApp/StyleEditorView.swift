import PhotoLabCore
import SwiftUI

let tokenLabels: [(token: String, label: String)] = [
    ("logo", "品牌 logo"), ("model", "機型"), ("model_auto", "機型（自動）"), ("brand_model", "品牌＋機型"),
    ("brand", "品牌"), ("lens", "鏡頭"), ("focal", "焦距"), ("aperture", "光圈"), ("shutter", "快門"),
    ("iso", "ISO"), ("exposure", "拍攝參數"), ("date", "日期時間"), ("custom", "自訂文字"),
]

private let tokenSymbols: [String: String] = [
    "logo": "seal", "brand": "seal", "model": "camera", "model_auto": "camera", "brand_model": "camera",
    "lens": "camera.aperture", "focal": "scope", "aperture": "circle.dashed", "shutter": "timer", "iso": "sun.max",
    "exposure": "slider.horizontal.3", "date": "calendar", "custom": "text.alignleft",
]

private let sizeChoices: [(label: String, value: Int)] = [("小", 85), ("稍小", 95), ("中", 100), ("大", 125), ("特大", 150)]
private let toneChoices: [(label: String, value: String)] = [("深墨", "strong"), ("中灰", "normal"), ("淺灰", "weak")]
private let blockTitles = ["left": "左側區塊", "center": "中間區塊", "right": "右側區塊"]
private let alignChoices: [(label: String, value: String)] = [("靠左", "left"), ("置中", "center"), ("靠右", "right")]

/// Design the footer: three blocks, each at most two lines, each line up to four items.
struct StyleEditorView: View {
    @Bindable var model: AppModel
    @State private var selection: ChipID?
    @State private var strip: NSImage?

    private struct StripKey: Equatable { let settings: Settings; let photo: URL? }
    struct ChipID: Equatable { let block: String; let line: Int; let index: Int }
    @State private var dropTarget: ChipID?
    @State private var trayTargeted = false
    @State private var activeBlock = "center"   // the block being edited is drawn wider
    @State private var endTarget: String?       // "block:line" while a drag hovers the end of that line

    private var style: FooterStyle { model.effectiveStyle }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Paper.gap + 4) {
                header
                previewStrip
                tray
                WeightedRow(weights: Self.blockNames.map { $0 == activeBlock ? 2.2 : 1 }, spacing: Paper.gap + 4) {
                    ForEach(Self.blockNames, id: \.self) { name in blockCard(name) }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: activeBlock)
            }
            .padding(16)
        }
        .font(.system(size: 13))
        .toggleStyle(PaperCheckboxStyle())
        .frame(minWidth: 1020, minHeight: 600)
        .background(Paper.bg)
        .task(id: StripKey(settings: model.settings, photo: model.selected)) {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            strip = await model.renderStrip()
        }
    }

    // MARK: header + preview

    private var header: some View {
        HStack(spacing: Paper.inner) {
            Text("資訊列樣式").font(.system(size: 18, weight: .bold))
            Text("把下方的項目拖進區塊，改了立刻套用")
                .font(.system(size: 12)).foregroundStyle(Paper.muted)
            Spacer()
            Menu {
                Section("從現成樣式開始（會取代目前的設定）") {
                    ForEach(Presets.footerLooks, id: \.name) { look in
                        Button(look.name) { model.startStyle(from: look.name) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("樣式：").foregroundStyle(Paper.muted)
                    Text(model.styleName).fontWeight(.semibold)
                }
            }
            .menuStyle(.button).buttonStyle(PaperButtonStyle(compact: true)).fixedSize()
            .help("目前使用的樣式。選單可以改從現成的樣式開始")
            Toggle("右側加分隔線", isOn: Binding(
                get: { style.divider },
                set: { on in model.editStyle { $0.divider = on } }))
            Button("匯入…") { model.importStyle() }.buttonStyle(PaperButtonStyle(compact: true))
            Button("匯出…") { model.exportStyle() }.buttonStyle(PaperButtonStyle(compact: true))
        }
    }

    private static let trayTokens: [(token: String, label: String)] = [
        ("logo", "品牌 logo"), ("model_auto", "機型"), ("lens", "鏡頭"), ("focal", "焦距"), ("exposure", "拍攝參數"),
        ("date", "日期"), ("custom", "自訂文字"),
    ]

    /// The elements to drag into a block; dropping a placed chip back here removes it.
    private var tray: some View {
        HStack(spacing: Paper.inner) {
            Text("項目").foregroundStyle(Paper.muted)
            ForEach(Self.trayTokens, id: \.token) { t in
                HStack(spacing: 6) {
                    Image(systemName: tokenSymbols[t.token] ?? "text.alignleft").font(.system(size: 11))
                    Text(t.label)
                }
                .padding(.horizontal, 10).frame(height: Paper.controlHeight)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Paper.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Paper.controlRadius).stroke(Paper.ink, lineWidth: Paper.thin))
                .draggable("photolab-token:\(t.token)")
            }
            Spacer(minLength: 0)
            Text("拖回這裡可移除").font(.system(size: 12)).foregroundStyle(Paper.muted)
        }
        .padding(.horizontal, Paper.pad).frame(height: 46)
        .background(Paper.fill.opacity(trayTargeted ? 1 : 0.6), in: RoundedRectangle(cornerRadius: Paper.radius))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first else { return false }
            return removeChip(raw)
        } isTargeted: { trayTargeted = $0 }
    }

    private var previewStrip: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.88))
            if let img = strip {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit().padding(.horizontal, Paper.pad)
            } else {
                Text("加入照片後這裡會顯示效果").foregroundStyle(Paper.muted)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: Paper.radius))
        .overlay(RoundedRectangle(cornerRadius: Paper.radius).stroke(Paper.ink, lineWidth: Paper.line))
    }

    // MARK: blocks

    private func blockCard(_ name: String) -> some View {
        let blk = style.block(name)
        return VStack(alignment: .leading, spacing: Paper.inner) {
            HStack(spacing: 6) {     // the handle: drag it onto another block to swap the two
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Paper.muted)
                Text(blockTitles[name] ?? name).font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .draggable("photolab-block:\(name)")
            .help("拖到另一個區塊上，兩個區塊的內容會對調")

            if blk.logo == "left" && !blk.lines.contains(where: { $0.items.contains("logo") }) {      // set by the built-in looks: the logo stands left of the whole text block
                HStack(spacing: 6) {
                    Image(systemName: "seal").font(.system(size: 11))
                    Text("品牌 logo（整塊文字左側）")
                    Button { model.editStyle { $0.modify(name) { $0.logo = "none" } } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Paper.muted)
                    .help("移除；要放回去，把「品牌 logo」拖進某一行")
                }
                .padding(.horizontal, 10).frame(height: Paper.compactHeight)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Paper.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Paper.controlRadius).stroke(Paper.ink, lineWidth: Paper.thin))
            }
            ForEach(Array(blk.lines.enumerated()), id: \.offset) { i, ln in
                lineEditor(name, i, ln)
            }
            if blk.lines.count < FooterStyle.maxLines {
                Button { model.editStyle { $0.modify(name) { $0.lines.append(StyleLine(items: ["lens"])) } } } label: {
                    Label("加一行", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperButtonStyle(compact: true))
            }

            Spacer(minLength: 0)
        }
        .toggleStyle(PaperCheckboxStyle())
        .padding(Paper.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: Paper.radius))
        .overlay(RoundedRectangle(cornerRadius: Paper.radius).stroke(Paper.ink, lineWidth: Paper.line))
        .simultaneousGesture(TapGesture().onEnded { activeBlock = name })
        .dropDestination(for: String.self) { items, _ in      // anywhere on the card, also when it has no line yet
            guard let raw = items.first else { return false }
            return dropOnBlock(raw, block: name)
        }
    }

    /// A drop on the card itself: goes to the first line with room; an empty block gets its first line.
    private func dropOnBlock(_ raw: String, block: String) -> Bool {
        if case .block(let src)? = Dragged(raw) { return edit { $0.swapBlocks(src, block) } }
        let lines = style.block(block).lines
        if let i = lines.firstIndex(where: { $0.items.count < FooterStyle.maxItems }) {
            return dropChip(raw, block: block, line: i, index: nil)
        }
        guard lines.count < FooterStyle.maxLines else { return false }
        model.editStyle { $0.modify(block) { $0.lines.append(StyleLine(items: [])) } }
        let ok = dropChip(raw, block: block, line: lines.count, index: nil)
        if !ok { model.editStyle { $0.modify(block) { $0.lines.removeLast() } } }
        return ok
    }

    private func lineEditor(_ block: String, _ li: Int, _ ln: StyleLine) -> some View {
        VStack(alignment: .leading, spacing: Paper.inner) {
            HStack {
                Text("第 \(li + 1) 行").font(.system(size: 12, weight: .semibold)).foregroundStyle(Paper.muted)
                Spacer()
                Button {
                    model.editStyle { $0.modify(block) { $0.lines.remove(at: li) } }
                    selection = nil
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Paper.muted).help("刪除這一行")
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(ln.items.enumerated()), id: \.offset) { ii, token in
                    chip(block, li, ii, token, count: ln.items.count)
                }
                if !ln.items.isEmpty { endSlot(block, li) }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay {
                if ln.items.isEmpty {
                    RoundedRectangle(cornerRadius: Paper.controlRadius)
                        .strokeBorder(Paper.muted, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .overlay(Text("拖到這裡").font(.system(size: 12)).foregroundStyle(Paper.muted))
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first else { return false }
                return dropChip(raw, block: block, line: li, index: nil)
            } isTargeted: { on in
                let key = "\(block):\(li)"
                if on { endTarget = key } else if endTarget == key { endTarget = nil }
            }

            HStack(spacing: Paper.inner) {
                Menu {
                    ForEach(sizeChoices, id: \.value) { s in
                        Button(s.label) { model.editStyle { $0.modify(block) { $0.lines[li].size = s.value } } }
                    }
                } label: { Text("字級 " + (sizeChoices.first { $0.value == ln.size }?.label ?? "\(ln.size)%")) }
                .menuStyle(.button).buttonStyle(PaperButtonStyle(compact: true)).fixedSize()
                Menu {
                    ForEach(toneChoices, id: \.value) { t in
                        Button(t.label) { model.editStyle { $0.modify(block) { $0.lines[li].color = t.value } } }
                    }
                } label: { Text("顏色 " + (toneChoices.first { $0.value == ln.color }?.label ?? ln.color)) }
                .menuStyle(.button).buttonStyle(PaperButtonStyle(compact: true)).fixedSize()
                Toggle("粗體", isOn: Binding(get: { ln.bold },
                    set: { v in model.editStyle { $0.modify(block) { $0.lines[li].bold = v } } }))
                Toggle("加線", isOn: Binding(get: { ln.sep == "divider" },
                    set: { v in model.editStyle { $0.modify(block) { $0.lines[li].sep = v ? "divider" : "gap" } } }))
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ block: String, _ li: Int, _ ii: Int, _ token: String, count: Int) -> some View {
        let id = ChipID(block: block, line: li, index: ii)
        let selected = selection == id
        return HStack(spacing: 6) {
            if selected && ii > 0 {
                Button { move(block, li, ii, -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            }
            Image(systemName: tokenSymbols[token] ?? "text.alignleft").font(.system(size: 11))
            Text(tokenLabels.first { $0.token == token }?.label ?? token)
            if selected && ii < count - 1 {
                Button { move(block, li, ii, 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            Button {
                model.editStyle { $0.modify(block) { $0.lines[li].items.remove(at: ii) } }
                selection = nil
            } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
            .buttonStyle(.plain).foregroundStyle(Paper.muted)
        }
        .padding(.horizontal, 10).frame(height: Paper.compactHeight)
        .background(selected ? Paper.fill : Color.white, in: RoundedRectangle(cornerRadius: Paper.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Paper.controlRadius).stroke(Paper.ink, lineWidth: Paper.thin))
        .overlay(alignment: .leading) {
            if dropTarget == id {
                RoundedRectangle(cornerRadius: 1).fill(Paper.ink).frame(width: 3, height: Paper.compactHeight + 6)
                    .offset(x: -5)
            }
        }
        .onTapGesture { selection = selected ? nil : id }
        .draggable(Self.payload(id))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first else { return false }
            return dropChip(raw, block: block, line: li, index: ii)
        } isTargeted: { on in
            if on { dropTarget = id } else if dropTarget == id { dropTarget = nil }
        }
    }

    /// The free spot after the last chip of a line: shows the insertion bar there and drops at the end.
    private func endSlot(_ block: String, _ li: Int) -> some View {
        let key = "\(block):\(li)"
        return Color.clear.frame(width: 26, height: Paper.compactHeight)
            .overlay(alignment: .leading) {
                if endTarget == key {
                    RoundedRectangle(cornerRadius: 1).fill(Paper.ink).frame(width: 3, height: Paper.compactHeight + 6)
                        .offset(x: -4)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first else { return false }
                return dropChip(raw, block: block, line: li, index: nil)
            } isTargeted: { on in
                if on { endTarget = key } else if endTarget == key { endTarget = nil }
            }
    }

    // MARK: drag and drop

    private static let blockNames = FooterStyle.blockNames

    private static func payload(_ id: ChipID) -> String { "photolab-chip:\(id.block):\(id.line):\(id.index)" }

    /// What a drag carries: a placed chip, a tray element or a whole block. Anything else is ignored.
    private enum Dragged {
        case chip(block: String, line: Int, index: Int), token(String), block(String)

        init?(_ raw: String) {
            let p = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if p.count == 4, p[0] == "photolab-chip", let l = Int(p[2]), let i = Int(p[3]) {
                self = .chip(block: p[1], line: l, index: i)
            } else if p.count == 2, p[0] == "photolab-token" {
                self = .token(p[1])
            } else if p.count == 2, p[0] == "photolab-block" {
                self = .block(p[1])
            } else { return nil }
        }
    }

    /// Applies one edit to the style; the editing rules themselves live in FooterStyle (and are unit tested).
    private func edit(_ op: (inout FooterStyle) -> Bool) -> Bool {
        var ok = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            model.editStyle { st in
                var copy = st
                if op(&copy) { st = copy; ok = true }
            }
        }
        selection = nil
        dropTarget = nil
        endTarget = nil
        return ok
    }

    /// A placed chip dropped on the tray is taken out of the style.
    private func removeChip(_ raw: String) -> Bool {
        guard case let .chip(b, l, i)? = Dragged(raw) else { return false }
        return edit { $0.removeItem(block: b, line: l, index: i) }
    }

    /// Drop on a chip / the end of a line: `index` is the slot it goes before (nil = the end).
    private func dropChip(_ raw: String, block: String, line: Int, index: Int?) -> Bool {
        guard let item = Dragged(raw) else { return false }
        switch item {
        case .block(let src):
            return edit { $0.swapBlocks(src, block) }
        case .token(let token):
            guard Self.trayTokens.contains(where: { $0.token == token }) else { return false }
            if Self.blockNames.contains(block) { activeBlock = block }
            return edit { $0.insertItem(token, block: block, line: line, before: index) }
        case .chip(let b, let l, let i):
            if Self.blockNames.contains(block) { activeBlock = block }
            return edit { $0.moveItem(fromBlock: b, line: l, index: i, toBlock: block, line: line, before: index) }
        }
    }

    private func move(_ block: String, _ li: Int, _ ii: Int, _ delta: Int) {
        model.editStyle { st in
            st.modify(block) { $0.lines[li].items.swapAt(ii, ii + delta) }
        }
        selection = ChipID(block: block, line: li, index: ii + delta)
    }
}

extension FooterStyle {
    mutating func modify(_ name: String, _ f: (inout StyleBlock) -> Void) {
        switch name {
        case "left": f(&left)
        case "right": f(&right)
        default: f(&center)
        }
    }
}

/// Three columns whose widths follow weights (the block being edited gets more); all share the tallest height.
struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get {
            let w = weights + [1, 1, 1]
            return AnimatablePair(w[0], AnimatablePair(w[1], w[2]))
        }
        set { weights = [newValue.first, newValue.second.first, newValue.second.second] }
    }

    private func widths(_ total: CGFloat, _ n: Int) -> [CGFloat] {
        let w = Array((weights + [1, 1, 1]).prefix(n))
        let sum = max(w.reduce(0, +), 0.001)
        let free = max(0, total - spacing * CGFloat(max(0, n - 1)))
        return w.map { free * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 900
        let ws = widths(total, subviews.count)
        var h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            h = max(h, v.sizeThatFits(ProposedViewSize(width: ws[i], height: nil)).height)
        }
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ws = widths(bounds.width, subviews.count)
        var x = bounds.minX
        for (i, v) in subviews.enumerated() {
            v.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: ws[i], height: bounds.height))
            x += ws[i] + spacing
        }
    }
}
