import Foundation
import PhotoLabCore

/// Built-in and user presets. A built-in preset is a complete look: whatever it does not mention goes back to the
/// base values, so applying it gives the same result whatever the previous state was (the user's own text, colour
/// choice and custom style stay).
enum Presets {
    static let maxUser = 50
    static let placeholder = "選擇預設…"

    static let builtin: [(name: String, values: [String: Any])] = [
        ("IG 4:5 白框", ["ratio": "4:5", "thickness": 10, "style": "white", "footer": false]),
        ("IG 1:1 白框", ["ratio": "1:1", "thickness": 10, "style": "white", "footer": false]),
        ("IG 4:5 + 相機資訊", ["ratio": "4:5", "thickness": 10, "style": "white", "footer": true]),
        ("模糊背景 4:5 + 相機資訊", ["ratio": "4:5", "thickness": 12, "style": "blur", "footer": true]),
        ("參考樣式 A：鏡頭粗體 + logo + 分隔線", [
            "ratio": "even", "thickness": 6, "style": "white", "footer": true, "main": "lens", "logo_pos": "right",
            "divider": true, "date_format": "ymd_dash_hm", "mirror": false, "bold": true,
            "exposure_order": "std", "font": "auto"]),
        ("參考樣式 B：左右對調 + SF Pro", [
            "ratio": "even", "thickness": 6, "style": "white", "footer": true, "main": "model", "logo_pos": "left",
            "divider": true, "date_format": "mdy_at_12h", "mirror": true, "bold": true,
            "exposure_order": "iso_first", "font": "sf"]),
    ]

    static var builtinNames: [String] { builtin.map(\.name) }

    /// One-click footer looks: only the footer is touched.
    static let footerLooks: [(name: String, values: [String: Any])] = [
        ("經典", [:]),
        ("簡約置中", ["layout": "center1", "fields": ["camera", "exposure"]]),
        ("logo 機型", ["layout": "custom", "footer_style": heroStyle, "exposure_order": "iso_first",
                  "exposure_items": ["aperture", "shutter", "iso"]]),
        ("只放 logo", ["layout": "logo"]),
        ("完整資訊", ["layout": "center2", "exposure_items": ["focal", "aperture", "shutter", "iso"]]),
        ("左右分開", ["layout": "split"]),
    ]

    /// logo 機型: logo + model on top, the shooting values and the date below, all centred.
    static let heroStyle: [String: Any] = [
        "center": ["align": "center", "logo": "none", "lines": [
            ["items": ["logo", "model_auto"], "bold": true, "size": 100, "color": "strong", "sep": "gap"],
            ["items": ["exposure", "date"], "bold": false, "size": 100, "color": "weak", "sep": "divider"],
        ]] as [String: Any],
        "left": ["align": "left", "lines": [Any]()] as [String: Any],
        "right": ["align": "right", "lines": [Any]()] as [String: Any],
        "divider": false,
    ]

    static func applyBuiltin(_ values: [String: Any], to s: inout Settings) {
        var n = Settings()
        n.customText = s.customText; n.colorChoice = s.colorChoice; n.customColor = s.customColor; n.style = s.style
        n.apply(values)
        s = n
    }

    static func applyLook(_ values: [String: Any], to s: inout Settings) {
        var n = s
        n.footerOn = true; n.layout = "classic3"; n.fields = ["camera", "lens", "exposure", "date"]
        n.divider = false; n.centerDivider = true; n.bold = true; n.logoPos = "left"; n.mainLens = false
        n.mirror = false; n.exposureItems = ["aperture", "shutter", "iso"]; n.exposureOrder = "std"
        n.apply(values)
        s = n
    }
}

extension Settings {
    /// Applies Python-style preset keys (ratio, thickness, style, footer, layout, main, ...) on top of the values.
    mutating func apply(_ d: [String: Any]) {
        if let r = d["ratio"] as? String, Settings.ratios.map(\.value).contains(r) { ratio = r }
        if let t = d["thickness"] as? NSNumber { thickness = min(50, max(0, t.doubleValue)) }
        if let st = d["style"] as? String { setStyleCode(st) }
        if let f = d["footer"] as? Bool { footerOn = f }
        if let l = d["layout"] as? String, Settings.layouts.map(\.value).contains(l) { layout = l }
        if let f = d["fields"] as? [String] { fields = Set(f) }
        if let v = d["divider"] as? Bool { divider = v }
        if let m = d["main"] as? String { mainLens = m == "lens" }
        if let v = d["mirror"] as? Bool { mirror = v }
        if let v = d["bold"] as? Bool { bold = v }
        if let p = d["logo_pos"] as? String, ["left", "right", "center"].contains(p) { logoPos = p }
        if let p = d["date_format"] as? String, Settings.dateFormats.map(\.value).contains(p) { dateFormat = p }
        if let e = d["exposure_items"] as? [String] { exposureItems = e }
        if let o = d["exposure_order"] as? String, FooterSpec.exposureOrders.contains(where: { $0.value == o }) { exposureOrder = o }
        if let f = d["font"] as? String { font = f }
        if d["footer_style"] != nil { style = FooterStyle.sanitize(d["footer_style"]) }
    }
}
