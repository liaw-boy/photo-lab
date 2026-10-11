import SwiftUI

/// The paper-wireframe look: white cards with black outlines, outlined buttons, a solid black main button, grey
/// selected segments, system font, always light.
enum Paper {
    static let ink = Color(red: 0.047, green: 0.047, blue: 0.047)
    static let bg = Color(red: 0.94, green: 0.94, blue: 0.94)
    static let fill = Color(red: 0.93, green: 0.93, blue: 0.93)
    static let muted = Color(red: 0.43, green: 0.43, blue: 0.43)
    static let line: CGFloat = 1.5          // outline of a card
    static let thin: CGFloat = 1.0          // outline of a control inside a card
    static let radius: CGFloat = 12         // card corner
    static let controlRadius: CGFloat = 8
    static let gap: CGFloat = 10            // between cards, and between groups inside a card
    static let inner: CGFloat = 6           // between controls of one group
    static let pad: CGFloat = 12            // card padding
    static let controlHeight: CGFloat = 30
    static let compactHeight: CGFloat = 26
}

struct PaperCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Paper.gap) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Paper.muted)
            content
        }
        .font(.system(size: 13))
        .padding(Paper.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: Paper.radius))
        .overlay(RoundedRectangle(cornerRadius: Paper.radius).stroke(Paper.ink, lineWidth: Paper.line))
    }
}

struct PaperButtonStyle: ButtonStyle {
    var filled = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: filled ? .bold : .regular))
            .foregroundStyle(filled ? Color.white : Paper.ink)
            .padding(.horizontal, 12)
            .frame(height: compact ? Paper.compactHeight : Paper.controlHeight)
            .background(filled ? Paper.ink : (configuration.isPressed ? Paper.fill : Color.white),
                        in: RoundedRectangle(cornerRadius: Paper.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Paper.controlRadius).stroke(Paper.ink, lineWidth: Paper.thin))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Check box: a rounded square with the same ink outline as the cards, filled with a white tick when on.
struct PaperCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5)
                        .fill(configuration.isOn ? Paper.ink : Color.white)
                    RoundedRectangle(cornerRadius: 4.5).stroke(Paper.ink, lineWidth: Paper.line)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 17, height: 17)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Switch: a pill that is solid ink when on, outlined when off.
struct PaperSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Paper.ink : Paper.fill)
                    Capsule().stroke(Paper.ink, lineWidth: Paper.line)
                    Circle().fill(Color.white)
                        .overlay(Circle().stroke(Paper.ink, lineWidth: configuration.isOn ? 0 : Paper.thin))
                        .frame(width: 16, height: 16).padding(.horizontal, 3)
                }
                .frame(width: 36, height: 22)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// One ratio tile: a pictogram (outer frame = the canvas, filled block = the photo) over its label.
struct RatioTile: View {
    let label: String
    let value: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RatioGlyph(value: value, color: selected ? .white : Paper.ink).frame(width: 28, height: 28)
                Text(label).font(.system(size: 11, weight: selected ? .bold : .regular))
            }
            .foregroundStyle(selected ? Color.white : Paper.ink)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(selected ? Paper.ink : Paper.fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Paper.ink, lineWidth: Paper.thin))
        }
        .buttonStyle(.plain)
    }
}

struct RatioGlyph: View {
    let value: String
    let color: Color
    private static let table: [String: (Double, Double)] = [
        "1:1": (1, 1), "2:3": (2, 3), "3:2": (3, 2), "4:5": (4, 5), "3:4": (3, 4), "5:4": (5, 4),
        "9:16": (9, 16), "16:9": (16, 9),
    ]

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 56            // drawn for a 56 unit square, like the Python tiles
            let box = 48.0
            func rect(_ w: Double, _ h: Double) -> CGRect {
                CGRect(x: (56 - w) / 2 * u, y: (56 - h) / 2 * u, width: w * u, height: h * u)
            }
            if value == "original" {
                ctx.fill(Path(roundedRect: rect(box, box * 2 / 3), cornerRadius: 4 * u), with: .color(color))
                return
            }
            var ow = box, oh = box * 0.74
            if value != "even", let r = Self.table[value] {
                let s = box / max(r.0, r.1)
                ow = (r.0 * s).rounded(); oh = (r.1 * s).rounded()
            }
            let outer = rect(ow, oh).insetBy(dx: 1.5 * u, dy: 1.5 * u)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 6 * u), with: .color(color), lineWidth: 3 * u)
            var iw = (ow * 0.62).rounded(), ih = (oh * 0.62).rounded()
            if value == "even" { iw = ow - 16; ih = oh - 16 }
            else if ["3:2", "16:9", "5:4"].contains(value) { iw = (ow * 0.7).rounded(); ih = (oh * 0.52).rounded() }
            ctx.fill(Path(roundedRect: rect(max(iw, 6), max(ih, 6)), cornerRadius: 3 * u), with: .color(color))
        }
    }
}

/// A drop-down that always shows the current choice.
struct PaperMenu: View {
    let title: String
    let options: [(label: String, value: String)]
    @Binding var selection: String

    var body: some View {
        HStack {
            if !title.isEmpty { Text(title).font(.system(size: 12)) }
            Menu {
                ForEach(options, id: \.value) { o in
                    Button(o.label) { selection = o.value }
                }
            } label: {
                Text(options.first(where: { $0.value == selection })?.label ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(PaperButtonStyle(compact: true))
        }
    }
}

/// Segmented control in the macOS manner: a grey track with a white thumb that slides (spring) to the chosen segment.
struct PaperSegmented<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    @Namespace private var thumb
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = o.value == selection
                Text(o.label)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(Paper.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: Paper.compactHeight - 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Paper.controlRadius - 2, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                                .overlay(RoundedRectangle(cornerRadius: Paper.controlRadius - 2, style: .continuous)
                                    .stroke(Paper.ink.opacity(0.12), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard enabled, !on else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = o.value }
                    }
            }
        }
        .padding(2)
        .background(Paper.fill, in: RoundedRectangle(cornerRadius: Paper.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Paper.controlRadius, style: .continuous)
            .stroke(Paper.ink, lineWidth: Paper.thin))
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(options.first(where: { $0.value == selection })?.label ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// Items wrap onto the next row when the line is too narrow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 400, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxW = max(maxW, x - spacing)
        }
        return (pts, CGSize(width: maxW, height: y + rowH))
    }
}

extension Color {
    init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
