import CryptoKit
import Foundation
import ImageIO

/// A short fingerprint of everything that decides how a photo is rendered. It is stored in every output as a JPEG
/// comment, which lets the "output already exists" question tell "made with the same settings" from "different".
public enum OutputSignature {
    static let prefix = "Photo_Lab sig="
    static let schema = "swift-1"

    public static func make(source: URL, settings: [String: Any]) -> String {
        var st = stat()
        var parts: [Any] = [source.lastPathComponent]
        if stat(source.path, &st) == 0 {
            parts += [Int(st.st_size), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)]
        }
        let payload: [String: Any] = ["src": parts, "settings": settings, "schema": schema]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    public static var commentPrefix: String { prefix }

    /// Which source photo an output was made from, as 16 hex characters: an HMAC with a key that only this Mac has
    /// (kept in the app's settings), so nothing about the photo can be read back from a shared picture.
    /// It is built from what stays the same when folders are renamed or moved, a disk mounts under another name,
    /// or the photo is edited (even cropped) and exported again from Lightroom: the file name, the capture time
    /// (with fractions of a second), the camera model and the camera's serial number when the file has one (it
    /// only goes into the HMAC, never into an output). A picture without a capture time (a screenshot, say) falls
    /// back to its path. Two copies of one photo get the same ID: they are the same picture.
    public static func sourceID(for source: URL, key: Data) -> String {
        sourceID(identity: identity(of: source), key: key)
    }

    static func sourceID(identity: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// What `sourceID` is built from (see there). Reads only the picture's metadata.
    static func identity(of source: URL) -> String {
        let name = source.lastPathComponent.lowercased()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let src = CGImageSourceCreateWithURL(source as CFURL, options),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any] {
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !taken.isEmpty {
                let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String ?? ""
                let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
                let serial = exif[kCGImagePropertyExifBodySerialNumber] as? String ?? ""
                return encode("capture", [name, taken, sub, model, serial])
            }
        }
        return encode("path", [source.standardizedFileURL.path])
    }

    /// Each field with its length in front, so no field text can make two different sets of fields read the same.
    private static func encode(_ kind: String, _ fields: [String]) -> String {
        kind + fields.map { "|\($0.utf8.count):\($0)" }.joined()
    }

    /// The comment text stored in an output: the signature, then the source ID when there is one.
    public static func comment(signature: String, source: String?) -> String {
        prefix + signature + (source.map { " src=" + $0 } ?? "")
    }

    /// Returns `jpeg` with a COM segment holding the signature right after the SOI marker.
    static func insertComment(_ comment: String, into jpeg: Data) -> Data {
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return jpeg }
        let text = Array(comment.utf8)
        guard text.count + 2 <= 0xFFFF else { return jpeg }
        var out = Data(capacity: jpeg.count + text.count + 4)
        out.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xFE, UInt8((text.count + 2) >> 8), UInt8((text.count + 2) & 0xFF)])
        out.append(contentsOf: text)
        out.append(jpeg.dropFirst(2))
        return out
    }

    /// The signature stored in an earlier output (nil for files made by other tools or older versions, and for an
    /// output cut off while it was written).
    public static func existing(at url: URL) -> String? {
        guard let info = read(at: url), info.complete else { return nil }
        return info.signature
    }

    /// What Photo_Lab wrote into `url`: its signature, the source ID (outputs from 1.2 on) and whether the file is
    /// complete (ends with the JPEG end marker; exFAT writes in place, so a crash can cut a file off). nil when the
    /// file is no Photo_Lab output. Reads only the first few KB (the comment comes right after the start marker)
    /// and the last two bytes.
    public static func read(at url: URL) -> OutputInfo? {
        // Only a regular file, opened without following a symlink and without blocking: a FIFO or device under an
        // output name must not stall the scan (it is then simply no Photo_Lab output).
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 8192), head.count > 4, head[0] == 0xFF, head[1] == 0xD8 else {
            return nil
        }
        var i = 2
        while i + 4 <= head.count, head[i] == 0xFF {
            let marker = head[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }                   // image data starts: no more headers
            let len = Int(head[i + 2]) << 8 | Int(head[i + 3])
            guard len >= 2, i + 2 + len <= head.count else { break }
            if marker == 0xFE {
                let body = head.subdata(in: (i + 4)..<(i + 2 + len))
                if let text = String(data: body, encoding: .utf8), text.hasPrefix(prefix) {
                    let fields = text.dropFirst(prefix.count).split(separator: " ")
                    let signature = fields.first.map { String($0.prefix(16)) }
                    let source = fields.first { $0.hasPrefix("src=") }.map { String($0.dropFirst(4).prefix(16)) }
                    var complete = false
                    if let end = try? h.seekToEnd(), end >= 2, (try? h.seek(toOffset: end - 2)) != nil,
                       let tail = try? h.read(upToCount: 2) {
                        complete = tail == Data([0xFF, 0xD9])
                    }
                    return OutputInfo(name: url.lastPathComponent, signature: signature, source: source,
                                      complete: complete)
                }
            }
            i += 2 + len
        }
        return nil
    }
}
