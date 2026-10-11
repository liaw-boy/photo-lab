import CoreText
import Foundation

/// Footer fonts: the system families of the Python renderer (Helvetica Neue by default), the user's own fonts in
/// `fonts/` (key `user:<file name>`), and PingFang for CJK text.
enum FontLibrary {
    static let maxFontBytes = 40 * 1024 * 1024

    /// key -> (regular PostScript name, bold PostScript name)
    static let system: [String: (String, String)] = [
        "auto": ("HelveticaNeue", "HelveticaNeue-Bold"),
        "pingfang": ("PingFangSC-Regular", "PingFangSC-Semibold"),
        "avenir": ("AvenirNext-Regular", "AvenirNext-Bold"),
        "futura": ("Futura-Medium", "Futura-Bold"),
        "optima": ("Optima-Regular", "Optima-Bold"),
        "gillsans": ("GillSans", "GillSans-Bold"),
        "palatino": ("Palatino-Roman", "Palatino-Bold"),
        "georgia": ("Georgia", "Georgia-Bold"),
        "didot": ("Didot", "Didot-Bold"),
        "menlo": ("Menlo-Regular", "Menlo-Bold"),
    ]

    static let labels: [(key: String, label: String)] = [
        ("auto", "Helvetica Neue (預設)"), ("sf", "SF Pro"), ("pingfang", "蘋方"), ("avenir", "Avenir Next"),
        ("futura", "Futura"), ("optima", "Optima"), ("gillsans", "Gill Sans"), ("palatino", "Palatino"),
        ("georgia", "Georgia"), ("didot", "Didot"), ("menlo", "Menlo (等寬)"),
    ]

    /// Every font that can really be loaded here: the system families plus the user's own in `fontsDir`.
    static func available(fontsDir: URL) -> [(key: String, label: String)] {
        var out = labels.filter { entry in
            if entry.key == "sf" { return true }
            guard let n = system[entry.key]?.0 else { return false }
            let f = CTFontCreateWithName(n as CFString, 12, nil)
            return (CTFontCopyPostScriptName(f) as String) == n
        }
        let root = fontsDir.resolvingSymlinksInPath()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for n in names.sorted() where userFontURL("user:" + n, fontsDir: fontsDir) != nil {
            out.append(("user:" + n, (n as NSString).deletingPathExtension))
        }
        return out
    }

    static func validKey(_ key: String?, fontsDir: URL) -> String {
        guard let key else { return "auto" }
        if key == "sf" || system[key] != nil { return key }
        if key.hasPrefix("user:"), userFontURL(key, fontsDir: fontsDir) != nil { return key }
        return "auto"
    }

    /// Only plain files directly inside the fonts folder, with a safe name and a sane size.
    static func userFontURL(_ key: String, fontsDir: URL) -> URL? {
        let name = String(key.dropFirst(5))
        let ok = name.range(of: #"^[\w .()+\-]{1,80}\.(ttf|otf|ttc)$"#, options: [.regularExpression, .caseInsensitive])
        guard ok != nil else { return nil }
        let root = fontsDir.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == root,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxFontBytes else { return nil }
        return file
    }

    static func font(size: CGFloat, bold: Bool, key: String, fontsDir: URL) -> CTFont {
        if key.hasPrefix("user:"), let url = userFontURL(key, fontsDir: fontsDir),
           let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descs.isEmpty {
            func isBold(_ d: CTFontDescriptor) -> Bool {
                let f = CTFontCreateWithFontDescriptor(d, size, nil)
                return CTFontGetSymbolicTraits(f).contains(.traitBold)
            }
            let pick = descs.first(where: { isBold($0) == bold }) ?? descs[0]
            return CTFontCreateWithFontDescriptor(pick, size, nil)
        }
        if key == "sf" {
            return CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
        }
        let names = system[key] ?? system["auto"]!
        return CTFontCreateWithName((bold ? names.1 : names.0) as CFString, size, nil)
    }

    static func cjk(size: CGFloat) -> CTFont {
        CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
    }
}
