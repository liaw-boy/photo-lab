import XCTest
import CoreGraphics
@testable import PhotoLabCore

/// Set PHOTOLAB_TEST_DIR to a folder on another volume (e.g. an exFAT disk or disk image) to run these there.
final class SaveJPEGTests: XCTestCase {
    private func scratch(base: URL? = nil) throws -> URL {
        let base = base ?? ProcessInfo.processInfo.environment["PHOTOLAB_TEST_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("photolab_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    private func assertExists(_ body: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case RenderError.exists = $0 else { return XCTFail("expected .exists, got \($0)", file: file, line: line) }
        }
    }

    /// Runs on whatever volume PHOTOLAB_TEST_DIR points at: the temp-file path on APFS, writeExclusive on exFAT.
    func testNoOverwriteSavesThenSkipsExisting() throws {
        let dir = try scratch()
        let dst = dir.appendingPathComponent("a.jpg"), empty = dir.appendingPathComponent("b.jpg")
        try Renderer.saveJPEG(Self.image(), to: dst, quality: 0.9, replace: false)
        let saved = try Data(contentsOf: dst)
        XCTAssertEqual(saved.prefix(2), Data([0xFF, 0xD8]), "a JPEG")
        XCTAssertEqual(saved.suffix(2), Data([0xFF, 0xD9]), "written to the end")
        assertExists(try Renderer.saveJPEG(Self.image(), to: dst, quality: 0.5, replace: false))
        XCTAssertEqual(try Data(contentsOf: dst), saved, "the existing file is left as it was")
        try Data().write(to: empty)                               // an empty file of the user's is a file like any other
        assertExists(try Renderer.saveJPEG(Self.image(), to: empty, quality: 0.9, replace: false))
        XCTAssertEqual(try Data(contentsOf: empty), Data())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["a.jpg", "b.jpg"],
                       "no temp files left")
    }

    func testOverwriteReplaces() throws {
        let dir = try scratch()
        let dst = dir.appendingPathComponent("a.jpg")
        try Data("old".utf8).write(to: dst)
        try Renderer.saveJPEG(Self.image(), to: dst, quality: 0.9, replace: true)
        XCTAssertEqual(try Data(contentsOf: dst).prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.jpg"])
    }

    func testWriteToMissingFolderFailsWithReadableReason() {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab_missing_\(UUID().uuidString)/a.jpg")
        XCTAssertThrowsError(try Renderer.saveJPEG(Self.image(), to: dst, quality: 0.9, replace: false)) {
            XCTAssertEqual(($0 as? RenderError)?.userMessage, "無法寫入輸出資料夾")
        }
    }

    /// Plays a volume like exFAT on any disk: the exclusive rename answers ENOTSUP when the name is free and EEXIST
    /// when it is taken, so the store falls back to writeExclusive, and leaves existing files alone.
    func testStoreFallsBackWhereExclusiveRenameIsTurnedDown() throws {
        let dir = try scratch()
        let exfatLike: (URL, URL) -> Int32 = { _, to in FileManager.default.fileExists(atPath: to.path) ? EEXIST : ENOTSUP }
        let dst = dir.appendingPathComponent("a.jpg"), tmp = dir.appendingPathComponent(".tmp")
        try Data("new".utf8).write(to: tmp)
        XCTAssertEqual(Renderer.storeWithoutOverwriting(Data("new".utf8), tmp: tmp, at: dst, renameExclusive: exfatLike), 0)
        XCTAssertEqual(try Data(contentsOf: dst), Data("new".utf8))
        try Data("again".utf8).write(to: tmp)
        XCTAssertEqual(Renderer.storeWithoutOverwriting(Data("again".utf8), tmp: tmp, at: dst, renameExclusive: exfatLike),
                       EEXIST)
        XCTAssertEqual(try Data(contentsOf: dst), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.jpg"], "temp file removed")
    }

    /// A JPEG cut off while being written still carries its signature in the header; it must not pass as finished.
    func testSignatureNeedsTheEndMarker() throws {
        let dir = try scratch()
        let dst = dir.appendingPathComponent("a.jpg")
        try Renderer.saveJPEG(Self.image(), to: dst, quality: 0.9, signature: "0123456789abcdef", replace: false)
        XCTAssertEqual(OutputSignature.existing(at: dst), "0123456789abcdef")
        let whole = try Data(contentsOf: dst)
        try whole.prefix(whole.count - 10).write(to: dst)
        XCTAssertNil(OutputSignature.existing(at: dst))
    }

    func testVolumesWithoutExclusiveRename() {
        for e in [ENOTSUP, EOPNOTSUPP, EINVAL, ENOSYS] { XCTAssertTrue(Renderer.lacksExclusiveRename(e), "errno \(e)") }
        for e in [EEXIST, EACCES, ENOSPC, EIO, 0] { XCTAssertFalse(Renderer.lacksExclusiveRename(e), "errno \(e)") }
    }

    // writeExclusive: called directly, so it runs on any volume.

    func testWriteExclusiveCreates() throws {
        let dst = try scratch().appendingPathComponent("a.jpg")
        XCTAssertEqual(Renderer.writeExclusive(Data("new".utf8), to: dst), 0)
        XCTAssertEqual(try Data(contentsOf: dst), Data("new".utf8))
    }

    func testWriteExclusiveMakesReadableFileWhateverTheUmask() throws {   // APFS: exFAT has no POSIX permissions
        let dst = try scratch(base: FileManager.default.temporaryDirectory).appendingPathComponent("a.jpg")
        let old = umask(0o077)
        defer { umask(old) }
        XCTAssertEqual(Renderer.writeExclusive(Data("new".utf8), to: dst), 0)
        let perms = try FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o644)
    }

    func testWriteExclusiveLeavesExistingFiles() throws {
        let dir = try scratch()
        let full = dir.appendingPathComponent("a.jpg"), empty = dir.appendingPathComponent("b.jpg")
        try Data("old".utf8).write(to: full)
        try Data().write(to: empty)
        XCTAssertEqual(Renderer.writeExclusive(Data("new".utf8), to: full), EEXIST)
        XCTAssertEqual(Renderer.writeExclusive(Data("new".utf8), to: empty), EEXIST)
        XCTAssertEqual(try Data(contentsOf: full), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: empty), Data())
    }

    func testWriteExclusiveIntoMissingFolderFails() {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab_missing_\(UUID().uuidString)/a.jpg")
        XCTAssertEqual(Renderer.writeExclusive(Data("new".utf8), to: dst), ENOENT)
    }

    /// Fills the disk: runs only with PHOTOLAB_TEST_FULL_DIR set to a folder on a small scratch volume (a disk image
    /// of a few MB), never on a real disk.
    func testWriteExclusiveRemovesItsFileWhenDiskIsFull() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOLAB_TEST_FULL_DIR"] else {
            throw XCTSkip("set PHOTOLAB_TEST_FULL_DIR to a folder on a small scratch volume")
        }
        let dst = try scratch(base: URL(fileURLWithPath: path)).appendingPathComponent("big.jpg")
        XCTAssertEqual(Renderer.writeExclusive(Data(count: 256 << 20), to: dst), ENOSPC)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path), "no partial file left")
    }
}
