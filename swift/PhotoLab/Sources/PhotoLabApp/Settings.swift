import Foundation
import PhotoLabCore

/// Everything the user can change in the side panel. Mirrors the Python GUI's settings.
struct Settings: Equatable {
    var ratio = "4:5"
    var thickness = 10.0
    var blurBackground = false
    var rounded = false
    var cornerPerMille = 12.0                       // 1...60, per mille of the long edge

    var footerOn = false
    var layout = "classic3"
    var fields: Set<String> = ["camera", "lens", "exposure", "date"]
    var customText = ""
    var logoPos = "left"
    var mirror = false
    var divider = false
    var centerDivider = true
    var mainLens = false
    var bold = true
    var dateFormat = "ymd_dot"
    var exposureItems: [String] = ["aperture", "shutter", "iso"]
    var exposureOrder = "std"
    var font = "auto"
    var textScale = 1.0
    var logoScale = 1.0
    var heightScale = 1.0
    var colorChoice = "auto"                        // auto | black | dark | white | custom
    var customColor = "#C0392B"
    var style = FooterStyle.default                 // the user-designed footer (layout "custom")

    init() {}

    static let ratios: [(label: String, value: String)] = [
        ("原始", "original"), ("平均", "even"), ("1:1", "1:1"), ("2:3", "2:3"), ("3:2", "3:2"),
        ("4:5", "4:5"), ("3:4", "3:4"), ("5:4", "5:4"), ("9:16", "9:16"), ("16:9", "16:9"),
    ]
    static let layouts: [(label: String, value: String)] = [
        ("經典三欄", "classic3"), ("置中一行", "center1"), ("置中兩行", "center2"), ("左右分開", "split"),
        ("只放 logo", "logo"), ("自訂樣式", "custom"),
    ]
    static let dateFormats: [(label: String, value: String)] = [
        ("2026.05.25", "ymd_dot"), ("2026-05-25", "ymd_dash"), ("2026/05/25", "ymd_slash"),
        ("25 May 2026", "dmy_text"), ("May 25, 2026", "mdy_text"),
        ("2026-05-25 14:22", "ymd_dash_hm"), ("2026-05-25 14:22:50", "ymd_dash_hms"),
        ("25 May 2026 14:22", "dmy_hm"), ("May 25, 2026 at 2:22:50 PM", "mdy_at_12h"),
    ]
    static let colors: [(label: String, value: String)] = [
        ("自動", "auto"), ("黑色", "black"), ("深灰", "dark"), ("白色", "white"), ("自訂…", "custom"),
    ]
    static let exposureOrders: [(label: String, value: String)] = {
        let names = ["focal": "焦距", "aperture": "光圈", "shutter": "快門", "iso": "ISO"]
        return FooterSpec.exposureOrders.map { o in (o.keys.compactMap { names[$0] }.joined(separator: " "), o.value) }
    }()
    static let exposureKeys: [(label: String, value: String)] = [
        ("焦距", "focal"), ("光圈", "aperture"), ("快門", "shutter"), ("ISO", "iso"),
    ]

    /// The renderer's frame style code for (blurred background, rounded corners).
    var styleCode: String {
        switch (blurBackground, rounded) {
        case (false, false): return "white"
        case (false, true): return "rounded"
        case (true, true): return "blur"
        case (true, false): return "blur_square"
        }
    }

    mutating func setStyleCode(_ code: String) {
        switch code {
        case "rounded": blurBackground = false; rounded = true
        case "blur": blurBackground = true; rounded = true
        case "blur_square": blurBackground = true; rounded = false
        default: blurBackground = false; rounded = false
        }
    }

    var renderOptions: RenderOptions {
        var o = RenderOptions()
        o.ratio = Ratio(ratio) ?? .fixed(w: 4, h: 5)
        o.thickness = thickness
        o.style = FrameStyle(rawValue: styleCode) ?? .white
        o.corner = cornerPerMille / 1000
        o.quality = 0.95
        return o
    }

    /// "#RRGGBB" for the chosen text colour, nil = automatic.
    var colorHex: String? {
        switch colorChoice {
        case "black": return "#111111"
        case "dark": return "#444444"
        case "white": return "#FFFFFF"
        case "custom": return customColor
        default: return nil
        }
    }

    /// The option names the renderer's `FooterSpec` reads (same as the Python renderer).
    var footerOptions: [String: Any] {
        var o: [String: Any] = [
            "footer": footerOn, "footer_layout": layout, "footer_fields": fields.sorted(),
            "footer_custom_text": customText, "footer_logo_pos": logoPos, "footer_mirror": mirror,
            "footer_divider": divider, "footer_center_divider": centerDivider, "footer_main": mainLens ? "lens" : "model",
            "footer_bold": bold, "footer_date_format": dateFormat, "footer_text_scale": textScale,
            "footer_logo_scale": logoScale, "footer_height_scale": heightScale,
            "footer_exposure_items": exposureItems, "footer_exposure_order": exposureOrder, "footer_font": font,
        ]
        if let c = colorHex { o["footer_color"] = c }
        if layout == "custom" { o["footer_style"] = style.json }
        return o
    }

    /// Everything that decides how a photo comes out (for the output fingerprint).
    var fingerprintSource: [String: Any] {
        var d = footerOn ? footerOptions : [:]
        d["ratio"] = ratio; d["thickness"] = thickness; d["style"] = styleCode; d["corner"] = cornerPerMille
        return d
    }

    // MARK: save / load (validated)

    var json: [String: Any] {
        [
            "ratio": ratio, "thickness": thickness, "blur_background": blurBackground, "rounded": rounded,
            "corner_per_mille": cornerPerMille, "footer_on": footerOn, "layout": layout,
            "fields": fields.sorted(), "custom_text": customText, "logo_pos": logoPos, "mirror": mirror,
            "divider": divider, "center_divider": centerDivider, "main_lens": mainLens, "bold": bold,
            "date_format": dateFormat, "exposure_items": exposureItems, "exposure_order": exposureOrder,
            "font": font, "text_scale": textScale, "logo_scale": logoScale, "height_scale": heightScale,
            "color_choice": colorChoice, "custom_color": customColor, "style": style.json, "focal_split": true,
        ]
    }

    /// Validated read: unknown / wrong-typed values keep their defaults, numbers are clamped.
    init(json o: [String: Any]) {
        self.init()
        func num(_ key: String, _ lo: Double, _ hi: Double, _ dflt: Double) -> Double {
            guard let n = o[key] as? NSNumber, !(o[key] is Bool), n.doubleValue.isFinite else { return dflt }
            return min(hi, max(lo, n.doubleValue))
        }
        func flag(_ key: String, _ dflt: Bool) -> Bool { (o[key] as? Bool) ?? dflt }
        func pick(_ key: String, _ allowed: [String], _ dflt: String) -> String {
            if let s = o[key] as? String, allowed.contains(s) { return s }
            return dflt
        }
        ratio = pick("ratio", Settings.ratios.map(\.value), ratio)
        thickness = num("thickness", 0, 50, thickness)
        blurBackground = flag("blur_background", blurBackground)
        rounded = flag("rounded", rounded)
        cornerPerMille = num("corner_per_mille", 1, 60, cornerPerMille)
        footerOn = flag("footer_on", footerOn)
        layout = pick("layout", Settings.layouts.map(\.value), layout)
        if let f = o["fields"] as? [Any] {
            fields = Set(f.compactMap { $0 as? String }).intersection(["camera", "lens", "exposure", "date"])
        }
        customText = Text.clean((o["custom_text"] as? String) ?? "", maxLength: 60)
        logoPos = pick("logo_pos", ["left", "right", "center"], logoPos)
        mirror = flag("mirror", mirror)
        divider = flag("divider", divider)
        centerDivider = flag("center_divider", centerDivider)
        mainLens = flag("main_lens", mainLens)
        bold = flag("bold", bold)
        dateFormat = pick("date_format", Settings.dateFormats.map(\.value), dateFormat)
        if let e = o["exposure_items"] as? [Any] {
            let set = Set(e.compactMap { $0 as? String })
            exposureItems = Settings.exposureKeys.map(\.value).filter { set.contains($0) }
        }
        exposureOrder = pick("exposure_order", Settings.exposureOrders.map(\.value), exposureOrder)
        if let f = o["font"] as? String, f == "auto" || FontKeys.isKnown(f) { font = f }
        textScale = num("text_scale", 0.5, 2.0, textScale)
        logoScale = num("logo_scale", 0.4, 2.5, logoScale)
        heightScale = num("height_scale", 0.6, 2.5, heightScale)
        colorChoice = pick("color_choice", Settings.colors.map(\.value), colorChoice)
        if let c = o["custom_color"] as? String, c.count == 7, c.hasPrefix("#"),
           c.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) { customColor = c.uppercased() }
        if o["style"] != nil {
            style = FooterStyle.sanitize(o["style"])
            if o["focal_split"] == nil, exposureItems.contains("focal") { style.splitFocal() }   // files from before
        }
    }
}

/// Font keys are re-validated against what is installed when the footer is rendered (`FooterSpec`); here only the
/// shape is checked, so a hand-edited file cannot smuggle in odd strings.
enum FontKeys {
    static func isKnown(_ key: String) -> Bool {
        if key.count > 90 { return false }
        let system: Set<String> = ["sf", "pingfang", "avenir", "futura", "optima", "gillsans", "palatino", "georgia",
                                   "didot", "menlo"]
        return system.contains(key) || (key.hasPrefix("user:") && !key.contains("/"))
    }
}
