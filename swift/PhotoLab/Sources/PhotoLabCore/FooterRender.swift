import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// A transparent RGBA bitmap (a piece of the footer), kept in the canvas colour space so that pasting it never
/// changes the numbers.
struct Piece {
    let image: CGImage
    var width: Int { image.width }
    var height: Int { image.height }
}

/// Port of `render_footer` and its helpers (`_row`, `_stack`, text and logo preparation).
struct FooterRenderer {
    let spec: FooterSpec
    let resources: Resources
    let space: CGColorSpace
    let onDark: Bool

    static let maxLogoBytes = 5 * 1024 * 1024
    static let maxLogoPixels = 25_000_000
    static let maxLogoWidth = 4096
    static let dark: [RGB] = [(30, 30, 30), (70, 70, 70), (135, 135, 135)]
    static let light: [RGB] = [(255, 255, 255), (238, 238, 238), (200, 200, 200)]

    // MARK: bitmaps

    func context(_ w: Int, _ h: Int) -> CGContext? {
        let c = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        c?.interpolationQuality = .high
        return c
    }

    func draw(_ p: Piece, in ctx: CGContext, x: Int, y: Int, canvasHeight: Int) {
        ctx.draw(p.image, in: CGRect(x: x, y: canvasHeight - y - p.height, width: p.width, height: p.height))
    }

    func resized(_ p: Piece, _ w: Int, _ h: Int) -> Piece? {
        guard let c = context(w, h) else { return nil }
        c.draw(p.image, in: CGRect(x: 0, y: 0, width: max(1, w), height: max(1, h)))
        return c.makeImage().map(Piece.init)
    }

    // MARK: text

    func text(_ s: String, size: Int, color: RGB, bold: Bool = false) -> Piece? {
        guard !s.isEmpty else { return nil }
        let px = CGFloat(max(1, size))
        var font = FontLibrary.font(size: px, bold: bold, key: spec.font, fontsDir: resources.fontsDir)
        if spec.font != "pingfang", s.unicodeScalars.contains(where: { $0.value > 0x2FF }) {
            font = FontLibrary.cjk(size: px)               // Latin fonts lack the glyphs of CJK text
        }
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard b.width.isFinite, b.height.isFinite, let c = context(Int(ceil(b.width)), Int(ceil(b.height))) else {
            return nil
        }
        c.setShouldSmoothFonts(false)
        c.setShouldAntialias(true)
        c.setFillColor(CGColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                               blue: CGFloat(color.b) / 255, alpha: 1))
        c.textPosition = CGPoint(x: -b.minX, y: -b.minY)
        CTLineDraw(line, c)
        FooterRenderer.embolden(c)
        return c.makeImage().map(Piece.init)
    }

    /// Core Graphics' grey-scale anti-aliasing comes out lighter than the FreeType rendering the Python renderer (and
    /// the preview people are used to) has; a gamma on the coverage brings the stroke weight back.
    static let textGamma: Double = {
        if let v = ProcessInfo.processInfo.environment["PHOTOLAB_TEXT_GAMMA"], let d = Double(v) { return d }
        return 2.2
    }()

    static func embolden(_ c: CGContext) {
        guard textGamma != 1.0, let base = c.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let n = c.bytesPerRow * c.height
        var lut = [UInt8](repeating: 0, count: 256)
        for a in 0..<256 { lut[a] = UInt8(min(255, max(0, (255 * pow(Double(a) / 255, 1 / textGamma)).rounded()))) }
        var i = 0
        while i + 3 < n {
            let a = Int(base[i + 3])
            if a > 0 && a < 255 {
                let na = Int(lut[a])
                for k in 0..<3 { base[i + k] = UInt8(min(255, Int(base[i + k]) * na / a)) }   // premultiplied
                base[i + 3] = UInt8(na)
            }
            i += 4
        }
    }

    // MARK: layout helpers

    /// Segments side by side, optional thin divider between them.
    func row(_ segs: [Piece?], gap: Int, divider: Bool, color: RGB = (0, 0, 0)) -> Piece? {
        let s = segs.compactMap { $0 }
        guard !s.isEmpty else { return nil }
        let h = s.map(\.height).max()!
        let n = s.count
        let dividers = divider ? n - 1 : 0
        let w = s.map(\.width).reduce(0, +) + dividers + gap * (n - 1 + dividers)
        guard let c = context(w, h) else { return nil }
        var x = 0
        for (i, p) in s.enumerated() {
            if i > 0 && divider {
                c.setFillColor(CGColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                       blue: CGFloat(color.b) / 255, alpha: 110.0 / 255))
                let top = Int((Double(h) * 0.1).rounded(.down)), bottom = Int((Double(h) * 0.9).rounded(.down))
                let lw = max(1, h / 14)
                c.fill(CGRect(x: x, y: h - bottom - 1, width: lw, height: bottom - top + 1))
                x += 1 + gap
            }
            draw(p, in: c, x: x, y: h - p.height, canvasHeight: h)      // bottom edges on one line
            x += p.width + gap
        }
        return c.makeImage().map(Piece.init)
    }

    /// Rows one above the other (two at most), aligned left / centre / right.
    func stack(_ rows: [Piece?], gap: Int, align: String) -> Piece? {
        let r = Array(rows.compactMap { $0 }.prefix(2))
        guard !r.isEmpty else { return nil }
        let w = r.map(\.width).max()!
        let h = r.map(\.height).reduce(0, +) + gap * (r.count - 1)
        guard let c = context(w, h) else { return nil }
        var y = 0
        for p in r {
            let x = align == "left" ? 0 : (align == "right" ? w - p.width : (w - p.width) / 2)
            draw(p, in: c, x: x, y: y, canvasHeight: h)
            y += p.height + gap
        }
        return c.makeImage().map(Piece.init)
    }

    // MARK: logos

    func logo(brand: String?, height: Int, normalize: Bool = false) -> Piece? {
        let slug = (brand ?? "").lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard !slug.isEmpty else { return nil }
        let names = onDark ? [slug + "_dark.png", slug + ".png"] : [slug + ".png"]
        let root = resources.logosDir.resolvingSymlinksInPath()
        for name in names {
            let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard file.deletingLastPathComponent() == root,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let bytes = (attrs[.size] as? NSNumber)?.intValue, bytes <= FooterRenderer.maxLogoBytes else {
                continue
            }
            var h = height
            if normalize, let probe = prepareLogo(file, height: 100) {
                h = max(8, Renderer.rnd(Double(height) / max(1.0, Double(probe.width) / Double(probe.height)).squareRoot()))
            }
            return prepareLogo(file, height: h)
        }
        return nil
    }

    /// Trims empty margins, scales to `height`, and makes a flat background fit the surface it is drawn on.
    func prepareLogo(_ file: URL, height: Int) -> Piece? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(src) > 0, (CGImageSourceGetType(src) as String?) == "public.png",
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil),
              raw.width * raw.height <= FooterRenderer.maxLogoPixels, raw.width > 0, raw.height > 0 else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = raw.width, h = raw.height
        var px = [UInt8](repeating: 0, count: w * h * 4)         // straight (not premultiplied) RGBA
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: srgb,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 0, to: px.count, by: 4) {          // un-premultiply
            let a = Int(px[i + 3])
            if a > 0 && a < 255 {
                for k in 0..<3 { px[i + k] = UInt8(min(255, Int(px[i + k]) * 255 / a)) }
            }
        }
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
        }
        var minA = 255
        for i in stride(from: 3, to: px.count, by: 4) { minA = min(minA, Int(px[i])) }
        let hasAlpha = minA < 250
        var bg: (Int, Int, Int)?
        var box: (Int, Int, Int, Int)?                           // x0, y0, x1, y1 (exclusive)
        func bounds(_ test: (Int, Int) -> Bool) -> (Int, Int, Int, Int)? {
            var x0 = w, y0 = h, x1 = -1, y1 = -1
            for y in 0..<h { for x in 0..<w where test(x, y) {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            } }
            return x1 < 0 ? nil : (x0, y0, x1 + 1, y1 + 1)
        }
        if hasAlpha {
            box = bounds { x, y in at(x, y).3 > 8 }
        } else {
            let cs = [at(0, 0), at(w - 1, 0), at(0, h - 1), at(w - 1, h - 1)]
            func near(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int)) -> Bool {
                abs(a.0 - b.0) <= 12 && abs(a.1 - b.1) <= 12 && abs(a.2 - b.2) <= 12
            }
            if cs.allSatisfy({ near($0, cs[0]) }) {              // flat background: find the artwork
                bg = (cs[0].0, cs[0].1, cs[0].2)
                box = bounds { x, y in
                    let p = at(x, y)
                    return max(abs(p.0 - cs[0].0), abs(p.1 - cs[0].1), abs(p.2 - cs[0].2)) > 24
                }
            }
        }
        let (bx0, by0, bx1, by1) = box ?? (0, 0, w, h)
        let cw = bx1 - bx0, ch = by1 - by0
        guard cw > 0, ch > 0, Double(cw) / Double(ch) <= 20, Double(ch) / Double(cw) <= 20 else { return nil }
        let s = min(Double(height) / Double(ch), Double(FooterRenderer.maxLogoWidth) / Double(cw))
        let th = max(1, Renderer.rnd(Double(ch) * s)), tw = max(1, Renderer.rnd(Double(cw) * s))
        // crop + scale with Core Graphics (premultiplied), then recolour when the artwork has a flat background
        var cropped = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            for x in 0..<cw {
                let si = ((by0 + y) * w + bx0 + x) * 4, di = (y * cw + x) * 4
                let a = Int(px[si + 3])
                cropped[di] = UInt8(Int(px[si]) * a / 255); cropped[di + 1] = UInt8(Int(px[si + 1]) * a / 255)
                cropped[di + 2] = UInt8(Int(px[si + 2]) * a / 255); cropped[di + 3] = UInt8(a)
            }
        }
        let provider = CGDataProvider(data: Data(cropped) as CFData)!
        guard let small = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cw * 4,
                                  space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let sc = context(tw, th) else { return nil }
        sc.draw(small, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = sc.makeImage() else { return nil }
        guard let bg else { return convert(scaled, to: nil) }
        // flat background -> alpha
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        let toAlpha: Bool
        if onDark, min(bg.0, bg.1, bg.2) > 235 { toAlpha = true } else if max(bg.0, bg.1, bg.2) < 25 { toAlpha = false }
        else { return convert(scaled, to: nil) }
        guard let rc = CGContext(data: &out, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw * 4,
                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        rc.draw(scaled, in: CGRect(x: 0, y: 0, width: tw, height: th))
        for i in stride(from: 0, to: out.count, by: 4) {
            let r = Int(out[i]), g = Int(out[i + 1]), b = Int(out[i + 2])      // opaque: premultiplied == straight
            if toAlpha {                                    // white background on a dark surface
                let a = 255 - min(r, g, b)
                out[i] = UInt8(r * a / 255); out[i + 1] = UInt8(g * a / 255); out[i + 2] = UInt8(b * a / 255)
                out[i + 3] = UInt8(a)
            } else {                                        // black background: luminance -> alpha
                let a = max(r, g, b)
                if a > 0 {
                    let k = 255.0 / Double(a)
                    let nr = min(255, Renderer.rnd(Double(r) * k)), ng = min(255, Renderer.rnd(Double(g) * k))
                    let nb = min(255, Renderer.rnd(Double(b) * k))
                    out[i] = UInt8(nr * a / 255); out[i + 1] = UInt8(ng * a / 255); out[i + 2] = UInt8(nb * a / 255)
                } else { out[i] = 0; out[i + 1] = 0; out[i + 2] = 0 }
                out[i + 3] = UInt8(a)
            }
        }
        let prov = CGDataProvider(data: Data(out) as CFData)!
        return CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tw * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent).map(Piece.init)
    }

    /// Redraws into the canvas colour space.
    func convert(_ img: CGImage, to _: Int?) -> Piece? {
        guard let c = context(img.width, img.height) else { return nil }
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return c.makeImage().map(Piece.init)
    }

    // MARK: the footer

    static func mix(_ c: RGB, _ t: RGB, _ k: Double) -> RGB {
        (Renderer.rnd(Double(c.r) * (1 - k) + Double(t.r) * k), Renderer.rnd(Double(c.g) * (1 - k) + Double(t.g) * k),
         Renderer.rnd(Double(c.b) * (1 - k) + Double(t.b) * k))
    }

    /// `includeFocal: false` is for a custom style that carries its own 焦距 element.
    func exposureText(includeFocal: Bool = true) -> String {
        let keys = FooterSpec.exposureOrders.first { $0.value == spec.exposureOrder }?.keys
            ?? ["focal", "aperture", "shutter", "iso"]
        let info = spec.info
        let values = ["focal": info.focal, "aperture": info.aperture, "shutter": info.shutter, "iso": info.iso]
        return keys.filter { spec.exposureItems.contains($0) && (includeFocal || $0 != "focal") }
            .compactMap { values[$0] ?? nil }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Returns 1 piece (centred), 2 (left + right) or 3 (+ centre), or nil when there is nothing to show.
    func render(baseBand: Int) -> [Piece?]? {
        let info = spec.info
        let theme = onDark ? FooterRenderer.light : FooterRenderer.dark
        var strong = theme[0], normal = theme[1], weak = theme[2]
        if let c = spec.color {
            let lum = 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
            strong = c; normal = c
            weak = lum > 170 ? FooterRenderer.mix(c, (0, 0, 0), 0.30) : FooterRenderer.mix(c, (255, 255, 255), 0.45)
        }
        let bold = spec.bold
        func T(_ t: String, _ size: Int, _ color: RGB, _ b: Bool = false) -> Piece? {
            text(t, size: size, color: color, bold: b)
        }
        let fs = max(10, Renderer.rnd(Double(baseBand) * 0.40 * spec.textScale))
        let lscale = spec.logoScale
        let gap = Renderer.rnd(Double(fs) * 1.1)
        let brand = info.brand
        let expTxt = exposureText()
        let dateTxt = info.dateParts != nil ? DateFormat.format(info.dateParts, spec.dateFormat, info.timeParts)
                                            : (info.date ?? "")
        let fullModel: String
        if let m = info.model, !m.isEmpty { fullModel = ((brand ?? "") + " " + m).trimmingCharacters(in: .whitespaces) }
        else { fullModel = brand ?? "" }
        let custom = spec.customText
        let customImg = custom.isEmpty ? nil : T(custom, Renderer.rnd(Double(fs) * 0.95), weak)
        let layout = spec.layout
        let fields = spec.fields
        func r(_ v: Double) -> Int { Renderer.rnd(v) }

        if layout == "logo" {
            var lg: Piece? = nil
            if let brand, !brand.isEmpty {
                lg = logo(brand: brand, height: r(Double(fs) * 2.6 * lscale))
                    ?? T(brand.uppercased(), r(Double(fs) * 1.5 * lscale), strong, bold)
            }
            let one = stack([lg, customImg], gap: r(Double(fs) * 0.5), align: "center")
            return one.map { [$0] }
        }

        if layout == "classic3" {
            let pos = spec.logoPos
            let mirror = spec.mirror
            let lensMain = spec.main == "lens"
            let lg = (fields.contains("camera") && brand != nil && !(brand!.isEmpty))
                ? logo(brand: brand, height: r(Double(fs) * 2.0 * lscale), normalize: true) : nil
            let model = lg != nil ? (info.model ?? "") : fullModel
            let hasModel = fields.contains("camera") && !model.isEmpty
            let hasLens = fields.contains("lens") && !(info.lens ?? "").isEmpty
            // the logo stands right beside the model name (same line), unless it belongs to another block
            let attach = lg != nil && ((pos == "left" && !mirror) || (mirror && !spec.divider))
            func withLogo(_ m: Piece?) -> Piece? {
                attach ? row([lg, m], gap: r(Double(gap) * 0.5), divider: false) : m
            }
            let outerLogo = attach ? nil : lg
            let nameLines: [Piece?]
            if lensMain {
                let l = hasLens ? T(info.lens!, fs, strong, bold) : nil
                let m = withLogo(hasModel ? T(model, r(Double(fs) * 0.95), weak) : nil)
                nameLines = [l, m]
            } else {
                let m = withLogo(hasModel ? T(model, fs, strong, bold) : nil)
                let l = hasLens ? T(info.lens!, r(Double(fs) * 0.95), weak) : nil
                nameLines = [m, l]
            }
            let expImg = (fields.contains("exposure") && !expTxt.isEmpty) ? T(expTxt, fs, strong, bold) : nil
            let dateImg = (fields.contains("date") && !dateTxt.isEmpty) ? T(dateTxt, r(Double(fs) * 0.95), weak) : nil
            let textGap = r(Double(fs) * 0.5)
            let namesL = stack(nameLines, gap: textGap, align: "left")
            let second = row([dateImg, customImg], gap: r(Double(fs) * 0.9), divider: false)
            let paramsR = stack([expImg, second], gap: textGap, align: "right")
            let paramsL = stack([expImg, second], gap: textGap, align: "left")
            var divider = spec.divider
            var left: Piece?, right: Piece?, centre: Piece?
            if mirror {
                left = paramsL
                right = row([outerLogo, namesL], gap: r(Double(gap) * 0.7), divider: divider, color: weak)
            } else if pos == "right" {
                left = namesL
                right = row([lg, paramsR], gap: r(Double(gap) * 0.7), divider: divider, color: weak)
                divider = false
            } else if pos == "center" {
                left = namesL; right = paramsR; centre = lg
            } else {
                left = row([outerLogo, namesL], gap: r(Double(gap) * 0.7), divider: false)
                right = paramsR
            }
            if divider && !mirror, let rt = right {
                right = row([spacer(1, rt.height), rt], gap: r(Double(gap) * 0.6), divider: true, color: weak)
            }
            let parts: [Piece?] = [left, right] + (centre != nil ? [centre] : [])
            return parts.contains(where: { $0 != nil }) ? parts : nil
        }

        if layout == "custom" {
            let style = spec.style
            let haveLogo = (brand != nil && !(brand!.isEmpty)) && logo(brand: brand, height: 12) != nil
            let texts: [String: String] = [
                "model": info.model ?? "", "model_auto": haveLogo ? (info.model ?? "") : fullModel,
                "brand_model": fullModel, "brand": brand ?? "", "lens": info.lens ?? "", "focal": info.focal ?? "",
                "aperture": info.aperture ?? "", "shutter": info.shutter ?? "", "iso": info.iso ?? "",
                "exposure": exposureText(includeFocal: false), "date": dateTxt, "custom": custom,
            ]
            let tones = ["strong": strong, "normal": normal, "weak": weak]
            func logoImg(_ pct: Int = 100) -> Piece? {
                guard let brand, !brand.isEmpty else { return nil }
                return logo(brand: brand, height: r(Double(fs) * 2.0 * lscale * Double(pct) / 100), normalize: true)
            }
            func styleLine(_ ln: StyleLine) -> Piece? {
                let size = max(8, r(Double(fs) * Double(ln.size) / 100))
                let color = tones[ln.color] ?? Color.hex(ln.color) ?? strong
                var imgs: [Piece?] = []
                for tok in ln.items {
                    if tok == "logo" { imgs.append(logoImg(ln.size)) }
                    else if let t = texts[tok], !t.isEmpty { imgs.append(T(t, size, color, ln.bold && bold)) }
                }
                let divided = ln.sep == "divider"
                return row(imgs, gap: divided ? gap : r(Double(fs) * 0.9), divider: divided, color: weak)
            }
            func buildBlock(_ name: String) -> Piece? {
                let blk = style.block(name)
                let st = stack(blk.lines.map(styleLine), gap: r(Double(fs) * 0.5), align: blk.align)
                // a logo element in the block's own lines replaces the "logo left of the block" flag
                let hasLogoItem = blk.lines.contains { $0.items.contains("logo") }
                if blk.logo == "left", !hasLogoItem, let lg = logoImg() {
                    return row([lg, st], gap: r(Double(gap) * 0.7), divider: blk.logoRule, color: weak)
                }
                return st
            }
            let left = buildBlock("left"), centre = buildBlock("center")
            var right = buildBlock("right")
            if style.divider, let rt = right {
                right = row([spacer(1, rt.height), rt], gap: r(Double(gap) * 0.6), divider: true, color: weak)
            }
            let parts: [Piece?] = [left, right, centre]
            return parts.contains(where: { $0 != nil }) ? parts : nil
        }

        // center1 / center2 / split
        var lg: Piece?
        if fields.contains("camera"), let brand, !brand.isEmpty {
            lg = logo(brand: brand, height: r(Double(fs) * 2.0 * lscale), normalize: true)
        }
        var cam: Piece?
        if fields.contains("camera") {
            var t = info.model ?? ""
            if lg == nil, let brand, !brand.isEmpty { t = (brand + " " + t).trimmingCharacters(in: .whitespaces) }
            cam = t.isEmpty ? nil : T(t, fs, strong, bold)
        }
        let lensP = (fields.contains("lens") && !(info.lens ?? "").isEmpty) ? T(info.lens!, fs, normal) : nil
        let expP = (fields.contains("exposure") && !expTxt.isEmpty) ? T(expTxt, fs, normal) : nil
        let dateP = (fields.contains("date") && !dateTxt.isEmpty) ? T(dateTxt, fs, normal) : nil
        let camRow = row([lg, cam], gap: r(Double(gap) * 0.5), divider: false)
        let cdiv = spec.centerDivider
        var parts: [Piece?]
        if layout == "center1" {
            parts = [row([camRow, lensP, expP, dateP, customImg], gap: gap, divider: cdiv, color: weak)]
        } else if layout == "center2" {
            parts = [stack([row([camRow, lensP], gap: gap, divider: cdiv, color: weak),
                            row([expP, dateP, customImg], gap: gap, divider: cdiv, color: weak)],
                           gap: r(Double(fs) * 0.5), align: "center")]
        } else {
            parts = [stack([camRow, lensP], gap: r(Double(fs) * 0.5), align: "left"),
                     stack([expP, row([dateP, customImg], gap: r(Double(fs) * 0.9), divider: false)],
                           gap: r(Double(fs) * 0.5), align: "right")]
        }
        parts = parts.filter { $0 != nil }
        return parts.isEmpty ? nil : parts
    }

    func spacer(_ w: Int, _ h: Int) -> Piece? {
        context(w, h)?.makeImage().map(Piece.init)
    }
}
