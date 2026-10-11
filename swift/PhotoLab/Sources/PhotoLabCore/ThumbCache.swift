import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Persistent thumbnail cache: small JPEGs keyed by a hash of (path, mtime, size, thumbnail size), so a folder opens
/// instantly the second time. Nothing in a file name comes from user text, the folder is private (0700) and owned by
/// us, a cache problem never blocks the app, and the folder is pruned when it grows. Safe to delete at any time.
public enum ThumbCache {
    static let version = "1"
    static let maxFiles = 8000
    static let maxBytes = 1_000_000                   // a cached thumbnail larger than this is not trusted

    public static let directory: URL = {
        if let custom = ProcessInfo.processInfo.environment["PHOTOLAB_CACHE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo_Lab", isDirectory: true).appendingPathComponent("thumbs_swift", isDirectory: true)
    }()

    /// The cached or freshly decoded thumbnail (long side `maxEdge`, orientation applied).
    public static func thumbnail(for url: URL, maxEdge: Int = 240) -> CGImage? {
        guard let file = cacheFile(for: url, maxEdge: maxEdge) else {
            return try? Renderer.loadPreview(url: url, maxEdge: maxEdge)
        }
        if let hit = load(file, maxEdge: maxEdge) { return hit }
        guard let img = try? Renderer.loadPreview(url: url, maxEdge: maxEdge) else { return nil }
        store(img, to: file)
        return img
    }

    static func cacheFile(for url: URL, maxEdge: Int) -> URL? {
        var st = stat()
        guard url.isFileURL, stat(url.path, &st) == 0 else { return nil }
        let mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        let key = "\(url.path)|\(mtimeNs)|\(st.st_size)|\(maxEdge)|v\(version)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)
        return directory.appendingPathComponent(digest + ".jpg")
    }

    static func load(_ file: URL, maxEdge: Int) -> CGImage? {
        var st = stat()
        guard stat(file.path, &st) == 0, st.st_size > 0, Int(st.st_size) <= maxBytes,
              let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier,
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width <= maxEdge, img.height <= maxEdge else { return nil }
        return img
    }

    /// Creates the folder if needed and makes sure it is a real directory that belongs to us and is private
    /// (a symlink or a foreign owner disables the cache; looser permissions are tightened).
    static func directoryOK() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return false }
        var st = stat()
        guard lstat(directory.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            return false
        }
        if st.st_mode & 0o077 != 0 { chmod(directory.path, 0o700) }
        return true
    }

    static func store(_ img: CGImage, to file: URL) {
        guard directoryOK() else { return }
        let tmp = directory.appendingPathComponent(".tmp_\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        chmod(tmp.path, 0o600)
        if rename(tmp.path, file.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Keeps the folder bounded: above `maxFiles`, the oldest fifth is deleted.
    public static func prune() {
        guard directoryOK() else { return }              // only a folder that is ours and private
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return }
        // only files that look like our own cache entries (40 hex digits), never anything else in the folder
        let jpgs = items.filter {
            $0.pathExtension == "jpg" && $0.deletingPathExtension().lastPathComponent.count == 40
                && $0.deletingPathExtension().lastPathComponent.allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        guard jpgs.count > maxFiles else { return }
        let dated = jpgs.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(jpgs.count / 5) { try? FileManager.default.removeItem(at: url) }
    }
}
