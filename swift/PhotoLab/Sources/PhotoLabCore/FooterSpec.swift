import Foundation

/// Where the user-supplied logos and fonts live.
public struct Resources: Sendable {
    public var logosDir: URL
    public var fontsDir: URL

    public init(logosDir: URL, fontsDir: URL) {
        self.logosDir = logosDir
        self.fontsDir = fontsDir
    }
}

/// Everything the footer needs, validated and clamped (`make_footer`).
public struct FooterSpec: Sendable {
    public var info = PhotoInfo()
    public var layout = "classic3"
    public var fields: Set<String> = ["camera", "lens", "exposure", "date"]
    public var divider = false
    public var centerDivider = true
    public var textScale = 1.0
    public var logoScale = 1.0
    public var heightScale = 1.0
    var color: RGB?
    public var bold = true
    public var dateFormat = "ymd_dot"
    public var logoPos = "left"
    public var customText = ""
    public var main = "model"
    public var mirror = false
    public var exposureItems = ["aperture", "shutter", "iso"]
    public var exposureOrder = "std"
    public var font = "auto"
    public var style = FooterStyle.default

    /// Orders of the exposure values; "std" and "iso_first" are the two the Python version knows.
    public static let exposureOrders: [(value: String, keys: [String])] = [
        ("std", ["focal", "aperture", "shutter", "iso"]),
        ("iso_first", ["iso", "aperture", "shutter", "focal"]),
        ("a_s_i_f", ["aperture", "shutter", "iso", "focal"]),
        ("f_i_a_s", ["focal", "iso", "aperture", "shutter"]),
        ("a_s_f_i", ["aperture", "shutter", "focal", "iso"]),
        ("s_a_i_f", ["shutter", "aperture", "iso", "focal"]),
        ("i_f_a_s", ["iso", "focal", "aperture", "shutter"]),
        ("f_s_a_i", ["focal", "shutter", "aperture", "iso"]),
    ]

    public static let layouts = ["classic3", "center1", "center2", "split", "logo", "custom"]
    static let exposureKeys = ["focal", "aperture", "shutter", "iso"]

    public init() {}

    /// [(key, label)] of every footer font available on this machine (system families + `fonts/`).
    public static func availableFonts(resources: Resources) -> [(key: String, label: String)] {
        FontLibrary.available(fontsDir: resources.fontsDir)
    }

    /// Builds a spec from the option names the Python renderer / GUI use (`footer_layout`, `footer_fields` ...).
    /// Returns nil when `footer` is off. `info` comes from the photo.
    public init?(options o: [String: Any], info: PhotoInfo, resources: Resources) {
        guard (o["footer"] as? Bool) == true else { return nil }
        self.info = info
        let all: Set<String> = ["camera", "lens", "exposure", "date"]
        if let f = o["footer_fields"] as? [Any] {
            fields = Set(f.compactMap { $0 as? String }).intersection(all)
        }
        if let l = o["footer_layout"] as? String, FooterSpec.layouts.contains(l) { layout = l }
        divider = (o["footer_divider"] as? Bool) == true
        if let c = o["footer_center_divider"] as? Bool { centerDivider = c }
        textScale = Clamp.value(o["footer_text_scale"], 0.5, 2.0, 1.0)
        logoScale = Clamp.value(o["footer_logo_scale"], 0.4, 2.5, 1.0)
        heightScale = Clamp.value(o["footer_height_scale"], 0.6, 2.5, 1.0)
        color = Color.hex(o["footer_color"])
        if let b = o["footer_bold"] as? Bool { bold = b }
        if let d = o["footer_date_format"] as? String, DateFormat.all.contains(d) { dateFormat = d }
        if let p = o["footer_logo_pos"] as? String, ["left", "right", "center"].contains(p) { logoPos = p }
        customText = Text.clean(o["footer_custom_text"] as? String ?? "", maxLength: 60)
        main = (o["footer_main"] as? String) == "lens" ? "lens" : "model"
        mirror = (o["footer_mirror"] as? Bool) == true
        if let e = o["footer_exposure_items"] as? [Any] {
            let set = Set(e.compactMap { $0 as? String })
            exposureItems = FooterSpec.exposureKeys.filter { set.contains($0) }
        }
        if let e = o["footer_exposure_order"] as? String, FooterSpec.exposureOrders.contains(where: { $0.value == e }) { exposureOrder = e }
        font = FontLibrary.validKey(o["footer_font"] as? String, fontsDir: resources.fontsDir)
        style = FooterStyle.sanitize(o["footer_style"])
    }
}
