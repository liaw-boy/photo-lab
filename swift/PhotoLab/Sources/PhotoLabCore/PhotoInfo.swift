import Foundation
import ImageIO

/// The few display strings of a photo's EXIF (never GPS or serial numbers). Mirrors `read_exif` of the Python
/// renderer: the same keys, the same formatting.
public struct PhotoInfo: Sendable, Equatable {
    public var brand: String?
    public var model: String?
    public var lens: String?
    public var focal: String?
    public var aperture: String?
    public var shutter: String?
    public var iso: String?
    public var date: String?
    public var dateParts: [String]?
    public var timeParts: [String]?

    public init() {}

    /// Placeholder text for a preview without a photo (`SAMPLE_INFO`).
    public static let sample: PhotoInfo = {
        var i = PhotoInfo()
        i.brand = "Camera"; i.model = "Model"; i.lens = "50mm F1.8"; i.focal = "50mm"; i.aperture = "f/1.8"
        i.shutter = "1/250s"; i.iso = "ISO100"; i.date = "2026.01.01"
        return i
    }()
}

public enum Text {
    /// Printable text only: control / format characters are dropped, white space collapsed, length capped.
    public static func clean(_ s: String, maxLength: Int = 48) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: continue
            default: out.append(u)
            }
        }
        let collapsed = String(out).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }

    /// Python's `"%g" % x`.
    static func g(_ x: Double) -> String { String(format: "%g", x) }
}

public enum ExifReader {
    static let brands: [(String, String)] = [
        ("sony", "Sony"), ("nikon", "Nikon"), ("canon", "Canon"), ("fujifilm", "Fujifilm"), ("fuji", "Fujifilm"),
        ("olympus", "Olympus"), ("om digital", "OM System"), ("om system", "OM System"), ("panasonic", "Panasonic"),
        ("leica", "Leica"), ("ricoh", "Ricoh"), ("pentax", "Pentax"), ("sigma", "Sigma"),
        ("hasselblad", "Hasselblad"), ("dji", "DJI"), ("apple", "Apple"), ("samsung", "Samsung"),
        ("google", "Google"), ("xiaomi", "Xiaomi"), ("huawei", "Huawei"), ("gopro", "GoPro"),
        ("insta360", "Insta360"),
    ]
    static let sonyModels: [String: String] = [
        "ILCE-7M4": "α7 IV", "ILCE-7M3": "α7 III", "ILCE-7M2": "α7 II", "ILCE-7RM5": "α7R V",
        "ILCE-7RM4": "α7R IV", "ILCE-7RM3": "α7R III", "ILCE-7SM3": "α7S III", "ILCE-7CM2": "α7C II",
        "ILCE-7C": "α7C", "ILCE-9M3": "α9 III", "ILCE-9M2": "α9 II", "ILCE-9": "α9", "ILCE-1": "α1",
        "ILCE-6700": "α6700", "ILCE-6600": "α6600", "ILCE-6400": "α6400", "ILCE-6100": "α6100",
    ]

    public static func read(url: URL) -> PhotoInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return PhotoInfo() }
        return info(from: props)
    }

    static func info(from props: [CFString: Any]) -> PhotoInfo {
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        func num(_ v: Any?) -> Double? {
            guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return nil }
            return d
        }
        var info = PhotoInfo()
        let make = Text.clean(tiff[kCGImagePropertyTIFFMake] as? String ?? "")
        let model = Text.clean(tiff[kCGImagePropertyTIFFModel] as? String ?? "")
        let low = make.lowercased()
        let brand = brands.first(where: { low.contains($0.0) })?.1 ?? (make.isEmpty ? "" : make.capitalized)
        if !brand.isEmpty { info.brand = brand }
        if !model.isEmpty {
            var m = model
            let firstWord = make.split(separator: " ").first.map(String.init) ?? ""
            for pre in [make, brand, firstWord] where !pre.isEmpty {
                if m.lowercased().hasPrefix(pre.lowercased() + " ") {
                    m = String(m.dropFirst(pre.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if brand == "Sony" { m = sonyModels[m.uppercased()] ?? m }
            info.model = m
        }
        let lens = Text.clean(exif[kCGImagePropertyExifLensModel] as? String ?? "")
        if !lens.isEmpty { info.lens = lens }
        if let f = num(exif[kCGImagePropertyExifFocalLength]), f > 0, f < 100_000 {
            info.focal = Text.g((f * 10).rounded(.toNearestOrEven) / 10) + "mm"
        }
        if let n = num(exif[kCGImagePropertyExifFNumber]), n > 0, n < 1000 {
            var s = String(format: "%.1f", n)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            info.aperture = "f/" + s
        }
        if let et = num(exif[kCGImagePropertyExifExposureTime]), et > 1e-9, et < 1e6 {
            info.shutter = et < 0.3 ? "1/\(Renderer.rnd(1 / et))s"
                                    : Text.g((et * 10).rounded(.toNearestOrEven) / 10) + "s"
        }
        var isoValue = exif[kCGImagePropertyExifISOSpeedRatings]
        if let arr = isoValue as? [Any] { isoValue = arr.first }
        if let iso = num(isoValue), iso > 0, iso < 10_000_000 { info.iso = "ISO\(Int(iso))" }
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String { parseDate(raw, into: &info) }
        return info
    }

    /// "2026:05:25 14:22:50" (also "-" separated, "T" between date and time).
    static func parseDate(_ raw: String, into info: inout PhotoInfo) {
        let pattern = #"^(\d{4})[:\-](\d{2})[:\-](\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return }
        func grp(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Range(r, in: raw).map { String(raw[$0]) }
        }
        guard let y = grp(1), let mo = grp(2), let d = grp(3) else { return }
        info.date = "\(y).\(mo).\(d)"
        info.dateParts = [y, mo, d]
        if let hh = grp(4), let mm = grp(5) { info.timeParts = [hh, mm, grp(6) ?? "00"] }
    }
}

enum DateFormat {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let all = ["ymd_dot", "ymd_dash", "ymd_slash", "dmy_text", "mdy_text",
                      "ymd_dash_hm", "ymd_dash_hms", "dmy_hm", "mdy_at_12h"]

    /// `fmt_date`: invalid dates give "".
    static func format(_ parts: [String]?, _ fmt: String, _ tparts: [String]?) -> String {
        guard let p = parts, p.count == 3, let mi = Int(p[1]), let di = Int(p[2]), (1...12).contains(mi),
              (1...31).contains(di) else { return "" }
        let y = p[0], mo = p[1], d = p[2]
        var hh: Int?, mm = 0, ss = 0
        if let t = tparts, t.count >= 3, let h = Int(t[0]), let m = Int(t[1]), let s = Int(t[2]),
           (0...23).contains(h), (0...59).contains(m), (0...59).contains(s) {
            hh = h; mm = m; ss = s
        }
        func hm() -> String { hh.map { String(format: " %02d:%02d", $0, mm) } ?? "" }
        switch fmt {
        case "ymd_dash": return "\(y)-\(mo)-\(d)"
        case "ymd_slash": return "\(y)/\(mo)/\(d)"
        case "dmy_text": return "\(di) \(months[mi - 1]) \(y)"
        case "mdy_text": return "\(months[mi - 1]) \(di), \(y)"
        case "ymd_dash_hm": return "\(y)-\(mo)-\(d)" + hm()
        case "ymd_dash_hms":
            return "\(y)-\(mo)-\(d)" + (hh.map { String(format: " %02d:%02d:%02d", $0, mm, ss) } ?? "")
        case "dmy_hm": return "\(di) \(months[mi - 1]) \(y)" + hm()
        case "mdy_at_12h":
            return "\(months[mi - 1]) \(di), \(y)" + (hh.map {
                String(format: " at %d:%02d:%02d %@", $0 % 12 == 0 ? 12 : $0 % 12, mm, ss, $0 < 12 ? "AM" : "PM")
            } ?? "")
        default: return "\(y).\(mo).\(d)"
        }
    }
}
