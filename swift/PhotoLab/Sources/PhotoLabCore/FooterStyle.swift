import Foundation

/// The user-designed footer: three blocks, each at most two lines of up to four items. Mirrors the style model of
/// the Python renderer, including `layout_to_style` and `sanitize_style`, so style files are shared.
public struct StyleLine: Sendable, Equatable {
    public var items: [String]
    public var bold = false
    public var size = 100
    public var color = "strong"          // strong | normal | weak | #RRGGBB
    public var sep = "gap"               // gap | divider

    public init(items: [String], bold: Bool = false, size: Int = 100, color: String = "strong", sep: String = "gap") {
        self.items = items; self.bold = bold; self.size = size; self.color = color; self.sep = sep
    }
}

public struct StyleBlock: Sendable, Equatable {
    public var align = "center"
    public var lines: [StyleLine] = []
    public var logo = "none"             // none | left
    public var logoRule = false

    public init(align: String = "center", lines: [StyleLine] = [], logo: String = "none", logoRule: Bool = false) {
        self.align = align; self.lines = lines; self.logo = logo; self.logoRule = logoRule
    }
}

public struct FooterStyle: Sendable, Equatable {
    public var left = StyleBlock(align: "left")
    public var center = StyleBlock(align: "center")
    public var right = StyleBlock(align: "right")
    public var divider = false

    public init(left: StyleBlock = StyleBlock(align: "left"), center: StyleBlock = StyleBlock(align: "center"),
                right: StyleBlock = StyleBlock(align: "right"), divider: Bool = false) {
        self.left = left; self.center = center; self.right = right; self.divider = divider
    }

    /// Plain JSON form (the keys of the Python style files), for saving and for `FooterSpec` options.
    public var json: [String: Any] {
        func lineJSON(_ l: StyleLine) -> [String: Any] {
            ["items": l.items, "bold": l.bold, "size": l.size, "color": l.color, "sep": l.sep]
        }
        func blockJSON(_ b: StyleBlock) -> [String: Any] {
            ["align": b.align, "lines": b.lines.map(lineJSON), "logo": b.logo, "logo_rule": b.logoRule]
        }
        return ["left": blockJSON(left), "center": blockJSON(center), "right": blockJSON(right), "divider": divider]
    }

    public func block(_ name: String) -> StyleBlock { name == "left" ? left : (name == "right" ? right : center) }

    static let tokens: Set<String> = ["model", "model_auto", "brand_model", "brand", "lens", "focal", "aperture",
                                      "shutter", "iso", "exposure", "date", "custom", "logo"]
    public static let maxLines = 2, maxItems = 8

    /// The default look (経典三欄).
    public static var `default`: FooterStyle { FooterStyle.fromLayout("classic3", LayoutOptions()) }

    public struct LayoutOptions: Sendable {
        public var fields: Set<String> = ["camera", "lens", "exposure", "date"]
        public var divider = false
        public var mirror = false
        public var main = "model"
        public var logoPos = "left"
        public var centerDivider = true
        public var focal = false             // the focal length is shown (as its own element before the exposure)
        public init() {}
    }

    /// `layout_to_style`
    public static func fromLayout(_ layout: String, _ o: LayoutOptions) -> FooterStyle {
        let cam = o.fields.contains("camera"), lens = o.fields.contains("lens")
        let expo = o.fields.contains("exposure"), date = o.fields.contains("date")
        let pos = ["left", "right", "center"].contains(o.logoPos) ? o.logoPos : "left"
        let shot = expo ? (o.focal ? ["focal", "exposure"] : ["exposure"]) : []

        func line(_ items: [String], bold: Bool = false, size: Int = 100, color: String = "strong",
                  sep: String = "gap") -> StyleLine? {
            items.isEmpty ? nil : StyleLine(items: items, bold: bold, size: size, color: color, sep: sep)
        }
        func lines(_ ls: StyleLine?...) -> [StyleLine] { ls.compactMap { $0 } }

        // the logo stands beside the model name (same line) where it belongs to the name block
        let attach = cam && layout == "classic3" && ((pos == "left" && !o.mirror) || (o.mirror && !o.divider))
        let modelItems = cam ? (attach ? ["logo", "model_auto"] : ["model_auto"]) : []
        let names: [StyleLine]
        if o.main == "lens" {
            names = lines(line(lens ? ["lens"] : [], bold: true),
                          line(modelItems, size: 95, color: "weak"))
        } else {
            names = lines(line(modelItems, bold: true),
                          line(lens ? ["lens"] : [], size: 95, color: "weak"))
        }
        let params = lines(line(shot, bold: true),
                           line((date ? ["date"] : []) + ["custom"], size: 95, color: "weak"))
        let empty = StyleBlock(align: "center")
        if layout == "center1" || layout == "center2" {
            let csep = o.centerDivider ? "divider" : "gap"
            let row1 = line((cam ? ["logo", "model_auto"] : []) + (lens ? ["lens"] : []), bold: true, sep: csep)
            let row2 = line(shot + (date ? ["date"] : []) + ["custom"], size: 100,
                            color: "normal", sep: csep)
            return FooterStyle(left: StyleBlock(align: "left"), center: StyleBlock(align: "center",
                               lines: lines(row1, row2)), right: StyleBlock(align: "right"))
        }
        if layout == "logo" {
            return FooterStyle(left: StyleBlock(align: "left"),
                               center: StyleBlock(align: "center", lines: lines(line(["logo"]),
                                                  line(["custom"], size: 95, color: "weak"))),
                               right: StyleBlock(align: "right"))
        }
        if o.mirror && layout == "classic3" {
            return FooterStyle(left: StyleBlock(align: "left", lines: params), center: empty,
                               right: StyleBlock(align: "left", lines: names,
                                                 logo: (cam && !attach) ? "left" : "none", logoRule: o.divider))
        }
        return FooterStyle(
            left: StyleBlock(align: "left", lines: names,
                             logo: (pos == "left" && cam && !attach) ? "left" : "none"),
            center: StyleBlock(align: "center", lines: (pos == "center" && cam) ? lines(line(["logo"])) : []),
            right: StyleBlock(align: "right", lines: params, logo: (pos == "right" && cam) ? "left" : "none",
                              logoRule: pos == "right" ? o.divider : false),
            divider: o.divider && pos != "right")
    }

    /// `sanitize_style`: any JSON value -> a valid style (unknown keys dropped, numbers clamped).
    public static func sanitize(_ obj: Any?) -> FooterStyle {
        let base = FooterStyle.default
        guard let dict = obj as? [String: Any] else { return base }
        var out = FooterStyle()
        out.divider = (dict["divider"] as? Bool) == true
        for name in ["left", "center", "right"] {
            guard let blk = dict[name] as? [String: Any] else {
                set(&out, name, base.block(name)); continue
            }
            var b = StyleBlock()
            let logo = blk["logo"] as? String
            b.logo = (logo == "left") ? "left" : "none"
            let align = blk["align"] as? String
            b.align = ["left", "center", "right"].contains(align ?? "") ? align! : base.block(name).align
            for case let ln as [String: Any] in (blk["lines"] as? [Any] ?? []).prefix(50) {
                if b.lines.count >= maxLines { break }
                let items = ((ln["items"] as? [Any]) ?? []).compactMap { $0 as? String }
                    .filter { tokens.contains($0) }.prefix(maxItems)
                if items.isEmpty { continue }
                var col = "strong"
                if let c = ln["color"] as? String, ["strong", "normal", "weak"].contains(c) || Color.hex(c) != nil {
                    col = c
                }
                let size = Int(Clamp.value(ln["size"], 50, 200, 100))
                b.lines.append(StyleLine(items: Array(items), bold: (ln["bold"] as? Bool) == true, size: size,
                                         color: col, sep: (ln["sep"] as? String) == "divider" ? "divider" : "gap"))
            }
            b.logoRule = (blk["logo_rule"] as? Bool) == true
            set(&out, name, b)
        }
        return out
    }

    private static func set(_ s: inout FooterStyle, _ name: String, _ b: StyleBlock) {
        switch name {
        case "left": s.left = b
        case "right": s.right = b
        default: s.center = b
        }
    }
}

enum Clamp {
    static func value(_ v: Any?, _ lo: Double, _ hi: Double, _ dflt: Double) -> Double {
        var d: Double?
        if let n = v as? NSNumber, !(v is Bool) { d = n.doubleValue }
        else if let s = v as? String { d = Double(s) }
        guard let x = d, x.isFinite else { return dflt }
        return min(hi, max(lo, x))
    }
}

typealias RGB = (r: Int, g: Int, b: Int)

enum Color {
    static func hex(_ value: Any?) -> RGB? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), s.count == 7, s.hasPrefix("#"),
              s.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let v = Int(s.dropFirst(), radix: 16) else { return nil }
        return (v >> 16 & 255, v >> 8 & 255, v & 255)
    }
}
