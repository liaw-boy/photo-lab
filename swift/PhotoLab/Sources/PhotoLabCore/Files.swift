import CoreGraphics
import Foundation
import ImageIO

/// Photo discovery, output naming and folder rules (`candidates`, `output_name`, `folders_conflict`).
public enum Files {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    /// Regular, non-hidden, non-symlink image files directly inside `dir`, sorted by name.
    public static func photos(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { url in
            guard extensions.contains(url.pathExtension.lowercased()) else { return false }
            let v = try? url.resourceValues(forKeys: Set(keys))
            return v?.isRegularFile == true && v?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `a.jpg` -> `a_ig.jpg`; other formats carry their extension so that a.jpg and a.png do not collide.
    public static func outputName(for src: URL) -> String {
        let ext = src.pathExtension.lowercased()
        let stem = src.deletingPathExtension().lastPathComponent
        return stem + ((ext == "jpg" || ext == "jpeg") ? "_ig.jpg" : "_\(ext)_ig.jpg")
    }

    /// `a_ig.jpg`, 2 -> `a_ig-2.jpg` (as Lightroom numbers a new name for an existing file).
    public static func numberedName(_ name: String, _ n: Int) -> String {
        let u = URL(fileURLWithPath: name)
        return u.deletingPathExtension().lastPathComponent + "-\(n)." + u.pathExtension
    }

    /// True when the folders are the same or one contains the other.
    public static func conflict(_ a: URL, _ b: URL) -> Bool {
        let x = a.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let y = b.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let n = min(x.count, y.count)
        return Array(x.prefix(n)) == Array(y.prefix(n))
    }
}

extension Renderer {
    /// A reduced copy for the live preview (EXIF orientation applied), at most `maxEdge` px on the long side.
    public static func loadPreview(url: URL, maxEdge: Int) throws -> CGImage {
        guard url.isFileURL, let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0
        else { throw RenderError.unreadable }
        guard let type = CGImageSourceGetType(src) as String?, acceptedTypes.contains(type) else {
            throw RenderError.unsupported
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
              pw > 0, ph > 0, pw * ph <= maxPixels else { throw RenderError.tooLarge }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, min(maxEdge, 8000)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw RenderError.unreadable
        }
        return img
    }
}

extension Renderer {
    /// `image` reduced (never enlarged) so that it fits `box` pixels, with Core Graphics' high-quality filter.
    public static func fitted(_ image: CGImage, into box: CGSize) -> CGImage {
        let k = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height), 1)
        guard k.isFinite, k > 0, k < 1 else { return image }
        let w = max(1, Int((CGFloat(image.width) * k).rounded())), h = max(1, Int((CGFloat(image.height) * k).rounded()))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
