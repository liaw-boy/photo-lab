import CryptoKit
import Foundation

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

    /// Returns `jpeg` with a COM segment holding the signature right after the SOI marker.
    static func insertComment(_ signature: String, into jpeg: Data) -> Data {
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return jpeg }
        let text = Array((prefix + signature).utf8)
        guard text.count + 2 <= 0xFFFF else { return jpeg }
        var out = Data(capacity: jpeg.count + text.count + 4)
        out.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xFE, UInt8((text.count + 2) >> 8), UInt8((text.count + 2) & 0xFF)])
        out.append(contentsOf: text)
        out.append(jpeg.dropFirst(2))
        return out
    }

    /// The signature stored in an earlier output (nil for files made by other tools or older versions).
    public static func existing(at url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 65_536), head.count > 4, head[0] == 0xFF, head[1] == 0xD8 else {
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
                    return String(text.dropFirst(prefix.count).prefix(16))
                }
            }
            i += 2 + len
        }
        return nil
    }
}
