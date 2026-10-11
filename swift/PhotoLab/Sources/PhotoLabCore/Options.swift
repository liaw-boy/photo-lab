import Foundation

/// Border settings, the same model as the Python renderer (`ig_border.py`).
public enum FrameStyle: String, Sendable, CaseIterable {
    case white, rounded, blur
    case blurSquare = "blur_square"

    var isBlur: Bool { self == .blur || self == .blurSquare }
}

public enum Ratio: Sendable, Equatable {
    case original
    case even
    case fixed(w: Int, h: Int)

    public static let table: [String: (Int, Int)] = [
        "1:1": (1, 1), "2:3": (2, 3), "3:2": (3, 2), "4:5": (4, 5),
        "3:4": (3, 4), "5:4": (5, 4), "9:16": (9, 16), "16:9": (16, 9),
    ]

    public init?(_ name: String) {
        switch name {
        case "original": self = .original
        case "even": self = .even
        default:
            guard let r = Ratio.table[name] else { return nil }
            self = .fixed(w: r.0, h: r.1)
        }
    }
}

public struct RenderOptions: Sendable {
    public var ratio: Ratio = .fixed(w: 4, h: 5)
    /// 0...50; 10 = a border of 5 % of the photo's long edge.
    public var thickness: Double = 10
    public var style: FrameStyle = .white
    /// Corner radius as a fraction of the long edge (rounded / blur styles), 0.001...0.08.
    public var corner: Double = 0.012
    /// JPEG quality 0...1.
    public var quality: Double = 0.95

    public init() {}
}

public enum RenderError: Error, CustomStringConvertible {
    case unreadable
    case unsupported
    case tooLarge
    case renderFailed
    case writeFailed
    case exists

    public var description: String {
        switch self {
        case .unreadable: return "cannot read the image"
        case .unsupported: return "unsupported image type"
        case .tooLarge: return "image too large"
        case .renderFailed: return "rendering failed"
        case .writeFailed: return "cannot write the output"
        case .exists: return "the output file already exists"
        }
    }
}
