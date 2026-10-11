import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photo + border -> new image. Mirrors `build_canvas` of the Python renderer (no footer yet).
public enum Renderer {
    static let padDivisor = 200.0
    static let maxPixels = 150_000_000
    static let acceptedTypes: Set<String> = ["public.jpeg", "public.png", "public.tiff"]
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: loading

    /// Decodes a JPEG / PNG / TIFF with its EXIF orientation applied, at full resolution.
    public static func load(url: URL) throws -> CGImage {
        guard url.isFileURL,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { throw RenderError.unreadable }
        guard let type = CGImageSourceGetType(src) as String?, acceptedTypes.contains(type) else {
            throw RenderError.unsupported
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int else { throw RenderError.unreadable }
        guard pw > 0, ph > 0, pw * ph <= maxPixels else { throw RenderError.tooLarge }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,        // applies the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),         // = full size, never scaled
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw RenderError.unreadable
        }
        return img
    }

    // MARK: rendering

    /// Python's `round()` (half to even), so that the geometry matches the reference renderer pixel for pixel.
    static func rnd(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    public static func render(_ photo: CGImage, options o: RenderOptions, footer: FooterSpec? = nil,
                              resources: Resources? = nil) throws -> CGImage {
        let w = photo.width, h = photo.height
        let longEdge = max(w, h)
        let space = photo.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!

        // footer pieces first: their height decides the size of the strip under the photo
        let baseBand = rnd(Double(longEdge) * 0.075)
        var bandH = baseBand
        var parts: [Piece?]?
        if let footer, let resources {
            bandH = rnd(Double(baseBand) * footer.heightScale)
            let fr = FooterRenderer(spec: footer, resources: resources, space: space, onDark: o.style.isBlur)
            parts = fr.render(baseBand: baseBand)
        }
        if case .original = o.ratio, parts == nil, o.style == .white { return photo }
        var ratio = o.ratio
        if case .original = ratio { ratio = .even }                       // a styled frame needs a border to live in

        let thickness = min(50, max(0, o.thickness))
        let pad = rnd(Double(longEdge) * thickness / padDivisor)
        var fh = parts != nil ? bandH : 0
        if let parts {                    // grow the strip when the text block is taller than the default band
            let need = parts.compactMap { $0?.height }.max() ?? 0
            fh = max(fh, need + rnd(Double(bandH) * 0.6) - pad)
        }
        let bw = w + 2 * pad, bh = h + 2 * pad + fh
        var cw = bw, ch = bh
        if case let .fixed(rw, rh) = ratio {
            let target = Double(rw) / Double(rh)
            if Double(cw) / Double(ch) < target { cw = rnd(Double(ch) * target) } else { ch = rnd(Double(cw) / target) }
        }

        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { throw RenderError.renderFailed }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        if o.style.isBlur { try drawBlurBackground(ctx, photo, cw, ch, space) }

        let ox = (cw - bw) / 2, oy = (ch - bh) / 2
        let px = ox + pad, py = oy + pad                                  // top-left coordinates
        let rect = CGRect(x: px, y: ch - py - h, width: w, height: h)     // CG is bottom-left based

        switch o.style {
        case .white:
            ctx.draw(photo, in: rect)
        case .blurSquare:
            drawShadow(ctx, rect, radius: 0, longEdge: longEdge, opacity: 0.50)
            ctx.draw(photo, in: rect)
        case .rounded, .blur:
            let c = min(0.08, max(0.001, o.corner.isFinite ? o.corner : 0.012))
            let r = max(2, rnd(Double(longEdge) * c))
            drawShadow(ctx, rect, radius: r, longEdge: longEdge, opacity: o.style.isBlur ? 0.50 : 0.22)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(r), cornerHeight: CGFloat(r), transform: nil))
            ctx.clip()
            ctx.draw(photo, in: rect)
            ctx.restoreGState()
        }
        if let parts, let resources, let footer {
            let fr = FooterRenderer(spec: footer, resources: resources, space: space, onDark: o.style.isBlur)
            placeFooter(fr, parts, in: ctx, canvasHeight: ch, px: px, py: py, w: w, h: h, pad: pad, fh: fh,
                        baseBand: baseBand)
        }
        guard let out = ctx.makeImage() else { throw RenderError.renderFailed }
        return out
    }

    /// Footer pieces under the photo: one centred, or left + right (+ a centre block in the free space).
    static func placeFooter(_ fr: FooterRenderer, _ parts: [Piece?], in ctx: CGContext, canvasHeight ch: Int, px: Int,
                            py: Int, w: Int, h: Int, pad: Int, fh: Int, baseBand: Int) {
        let yMid = Double(py + h) + Double(pad + fh) / 2          // centre of the strip under the photo
        let gapMid = rnd(Double(baseBand) * 0.5)
        func top(_ p: Piece) -> Int { rnd(yMid - Double(p.height) / 2) }
        if parts.count == 1 {
            guard var p = parts[0] else { return }
            if p.width > w, let q = fr.resized(p, w, max(1, rnd(Double(p.height) * Double(w) / Double(p.width)))) { p = q }
            fr.draw(p, in: ctx, x: px + (w - p.width) / 2, y: top(p), canvasHeight: ch)
            return
        }
        var left = parts[0], right = parts[1]
        var centre: Piece? = parts.count > 2 ? parts[2] : nil
        let widths = [left, right, centre].compactMap { $0?.width }
        let total = widths.reduce(0, +) + gapMid * (widths.count - 1)
        let s = total > 0 ? min(1.0, Double(w) / Double(total)) : 1.0
        func fit(_ p: Piece?) -> Piece? {
            guard let p, s < 1 else { return p }
            return fr.resized(p, max(1, rnd(Double(p.width) * s)), max(1, rnd(Double(p.height) * s))) ?? p
        }
        left = fit(left); right = fit(right); centre = fit(centre)
        if let l = left { fr.draw(l, in: ctx, x: px, y: top(l), canvasHeight: ch) }
        if let r = right { fr.draw(r, in: ctx, x: px + w - r.width, y: top(r), canvasHeight: ch) }
        if let c = centre {                       // middle of the free space between the two blocks
            let lend = px + (left?.width ?? 0)
            let rstart = px + w - (right?.width ?? 0)
            var cx = (lend + rstart - c.width) / 2
            cx = min(max(cx, lend), max(lend, rstart - c.width))
            fr.draw(c, in: ctx, x: cx, y: top(c), canvasHeight: ch)
        }
    }

    /// Photo scaled to cover the canvas, heavily blurred (at 1/4 size) and darkened by 28 %.
    static func drawBlurBackground(_ ctx: CGContext, _ photo: CGImage, _ cw: Int, _ ch: Int,
                                   _ space: CGColorSpace) throws {
        let sw = max(8, cw / 4), sh = max(8, ch / 4)
        let s = max(Double(sw) / Double(photo.width), Double(sh) / Double(photo.height))
        let tw = max(sw, rnd(Double(photo.width) * s)), th = max(sh, rnd(Double(photo.height) * s))
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RenderError.renderFailed
        }
        small.interpolationQuality = .medium
        small.draw(photo, in: CGRect(x: (sw - tw) / 2, y: (sh - th) / 2, width: tw, height: th))
        guard let smallImg = small.makeImage() else { throw RenderError.renderFailed }
        let sigma = Double(max(sw, sh)) * 0.045
        let blurred = CIImage(cgImage: smallImg).clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let blurImg = ciContext.createCGImage(blurred, from: blurred.extent, format: .RGBA8, colorSpace: space)
        else { throw RenderError.renderFailed }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(blurImg, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.restoreGState()
    }

    /// Soft drop shadow: a rounded-rect mask blurred with sigma m/2.5, offset down by 0.35 m.
    static func drawShadow(_ ctx: CGContext, _ rect: CGRect, radius: Int, longEdge: Int, opacity: Double) {
        let m = max(4, rnd(Double(longEdge) * 0.03))
        let mw = Int(rect.width) + 2 * m, mh = Int(rect.height) + 2 * m
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let mctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        mctx.setFillColor(gray: CGFloat(opacity), alpha: 1)
        let box = CGRect(x: m, y: m, width: Int(rect.width), height: Int(rect.height))
        mctx.addPath(CGPath(roundedRect: box, cornerWidth: CGFloat(radius), cornerHeight: CGFloat(radius), transform: nil))
        mctx.fillPath()
        guard let maskImg = mctx.makeImage() else { return }
        let blurred = CIImage(cgImage: maskImg).clampedToExtent().applyingGaussianBlur(sigma: Double(m) / 2.5)
            .cropped(to: CGRect(x: 0, y: 0, width: mw, height: mh))
        guard let soft = ciContext.createCGImage(blurred, from: blurred.extent, format: .L8, colorSpace: gray) else {
            return
        }
        // soft is a grey ramp whose value is the shadow's opacity: white paints, black leaves the canvas alone.
        let dy = CGFloat(rnd(Double(m) * 0.35))
        let target = CGRect(x: rect.minX - CGFloat(m), y: rect.minY - CGFloat(m) - dy, width: CGFloat(mw),
                            height: CGFloat(mh))
        ctx.saveGState()
        ctx.clip(to: target, mask: soft)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(target)
        ctx.restoreGState()
    }

    // MARK: saving

    /// Writes a JPEG (embeds the colour profile of the image); atomic: a temp file in the same folder, then rename.
    /// `signature` is stored as a JPEG comment (see `OutputSignature`). With `replace: false` an existing file is
    /// never touched (the check and the move are one atomic step), and `RenderError.exists` is thrown.
    public static func saveJPEG(_ image: CGImage, to url: URL, quality: Double, signature: String? = nil,
                                replace: Bool = true) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".ig_tmp_\(UUID().uuidString).jpg")
        let q = Int((min(1, max(0, quality)) * 100).rounded())
        var data: Data
        if let own = JPEGEncoder.encode(image, quality: q, comment: signature.map { OutputSignature.commentPrefix + $0 }) {
            data = own                                           // 4:4:4, profile embedded, signature in a COM segment
        } else {                                                 // (cannot happen for our canvases; ImageIO as a fallback)
            let buffer = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw RenderError.writeFailed
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw RenderError.writeFailed }
            data = buffer as Data
            if let signature { data = OutputSignature.insertComment(signature, into: data) }
        }
        do {
            try data.write(to: tmp, options: [])
            chmod(tmp.path, 0o644)
            let rc = replace ? rename(tmp.path, url.path) : renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL))
            if rc != 0 {
                let exists = errno == EEXIST
                try? FileManager.default.removeItem(at: tmp)
                throw exists ? RenderError.exists : RenderError.writeFailed
            }
        } catch let e as RenderError {
            throw e
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw RenderError.writeFailed
        }
    }
}
