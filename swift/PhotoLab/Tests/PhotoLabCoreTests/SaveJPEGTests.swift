import XCTest
import CoreGraphics
@testable import PhotoLabCore

final class SaveJPEGTests: XCTestCase {
    /// Set PHOTOLAB_TEST_DIR to a folder on another volume (e.g. exFAT) to test there.
    func testNoOverwriteSavesThenSkipsExisting() throws {
        let base = ProcessInfo.processInfo.environment["PHOTOLAB_TEST_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("photolab_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let dst = dir.appendingPathComponent("a.jpg")
        try Renderer.saveJPEG(img, to: dst, quality: 0.9, replace: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        XCTAssertThrowsError(try Renderer.saveJPEG(img, to: dst, quality: 0.9, replace: false)) {
            guard case RenderError.exists = $0 else { return XCTFail("expected .exists, got \($0)") }
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, ["a.jpg"], "no temp files left behind")
    }
}
