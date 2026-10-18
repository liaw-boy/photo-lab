import XCTest
import CoreGraphics
import ImageIO
@testable import PhotoLabCore

final class ExportNamingTests: XCTestCase {
    private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private let key = Data(repeating: 7, count: 32)
    private func id(_ path: String) -> String { OutputSignature.sourceID(for: u(path), key: key) }

    /// An index as `ExportPlan.scan` returns it: a Photo_Lab output with a source ID, an old one without, or a
    /// file of another tool.
    private func ours(_ name: String, _ src: String) -> (String, OutputInfo) {
        (name, OutputInfo(name: name, signature: "0123456789abcdef", source: id(src), complete: true))
    }
    private func legacy(_ name: String) -> (String, OutputInfo) {
        (name, OutputInfo(name: name, signature: "0123456789abcdef", source: nil, complete: true))
    }
    private func foreign(_ name: String) -> (String, OutputInfo) {
        (name, OutputInfo(name: name, signature: nil, source: nil, complete: false))
    }
    /// The plan without the source IDs (checked once in testEntriesCarryTheSourceID).
    private func plan(_ paths: [String], _ index: [(String, OutputInfo)]) -> [ExportEntry] {
        ExportPlan.plan(sources: paths.map(u), ids: paths.map(id), index: Dictionary(uniqueKeysWithValues: index))
            .map { ExportEntry(name: $0.name, own: $0.own, complete: $0.complete) }
    }

    func testEntriesCarryTheSourceID() {             // when it was worked out (its family has files there)
        let index = Dictionary(uniqueKeysWithValues: [ours("IMG_1_ig.jpg", "/a/IMG_1.jpg")])
        let e = ExportPlan.plan(sources: [u("/a/IMG_1.jpg")], ids: [id("/a/IMG_1.jpg")], index: index)
        XCTAssertEqual(e.first?.source, id("/a/IMG_1.jpg"))
    }

    func testNumberedName() {
        XCTAssertEqual(Files.numberedName("IMG_1234_ig.jpg", 2), "IMG_1234_ig-2.jpg")
        XCTAssertEqual(Files.numberedName("a_png_ig.jpg", 12), "a_png_ig-12.jpg")
    }

    func testFamily() {
        XCTAssertEqual(ExportPlan.family(of: "IMG_1_ig.jpg")?.stem, "img_1_ig")
        XCTAssertEqual(ExportPlan.family(of: "IMG_1_ig.jpg")?.number, 1)
        XCTAssertEqual(ExportPlan.family(of: "IMG_1_IG-12.JPG")?.number, 12)
        XCTAssertEqual(ExportPlan.family(of: "x_ig-2_ig.jpg")?.stem, "x_ig-2_ig", "a source named x_ig-2.jpg")
        for bad in ["IMG_1.jpg", "a_ig-1.jpg", "a_ig-02.jpg", "a_ig-.jpg", "a_ig-x.jpg", "a_ig.png", "a_ig-1234567.jpg"] {
            XCTAssertNil(ExportPlan.family(of: bad), bad)
        }
    }

    func testSourceIDDependsOnPathAndKey() {
        XCTAssertEqual(id("/a/IMG_1.jpg"), id("/a/IMG_1.jpg"))
        XCTAssertNotEqual(id("/a/IMG_1.jpg"), id("/b/IMG_1.jpg"))
        XCTAssertNotEqual(id("/a/IMG_1.jpg"), OutputSignature.sourceID(for: u("/a/IMG_1.jpg"), key: Data(count: 32)))
        XCTAssertEqual(id("/a/IMG_1.jpg").count, 16)
    }

    func testEmptyFolder() {
        let e = plan(["/a/IMG_1.jpg", "/a/IMG_2.jpg", "/a/IMG_1.png"], [])
        XCTAssertEqual(e.map(\.name), ["IMG_1_ig.jpg", "IMG_2_ig.jpg", "IMG_1_png_ig.jpg"])
        XCTAssertEqual(e.map(\.own), [false, false, false])
    }

    func testSameNamesInOneExportGetNumbers() {
        let e = plan(["/t1/IMG_0001.jpg", "/t2/IMG_0001.jpg", "/t3/img_0001.JPG"], [])
        XCTAssertEqual(e.map(\.name), ["IMG_0001_ig.jpg", "IMG_0001_ig-2.jpg", "img_0001_ig-3.jpg"])
    }

    /// The review's case: trip1 and trip2 were exported together; later only trip2 is. It must find its own -2
    /// file, never trip1's plain one.
    func testAPhotoFindsItsOwnOutputWhateverIsSelected() {
        let index = [ours("IMG_0001_ig.jpg", "/t1/IMG_0001.jpg"), ours("IMG_0001_ig-2.jpg", "/t2/IMG_0001.jpg")]
        XCTAssertEqual(plan(["/t2/IMG_0001.jpg"], index), [ExportEntry(name: "IMG_0001_ig-2.jpg", own: true)])
        XCTAssertEqual(plan(["/t2/IMG_0001.jpg", "/t1/IMG_0001.jpg"], index),
                       [ExportEntry(name: "IMG_0001_ig-2.jpg", own: true), ExportEntry(name: "IMG_0001_ig.jpg", own: true)])
    }

    func testAnotherPhotosFileIsNeverTaken() {
        let index = [ours("IMG_0001_ig.jpg", "/t1/IMG_0001.jpg"), ours("IMG_0001_ig-2.jpg", "/t2/IMG_0001.jpg")]
        XCTAssertEqual(plan(["/t3/IMG_0001.jpg"], index), [ExportEntry(name: "IMG_0001_ig-3.jpg", own: false)])
    }

    func testOutputsBefore12CountForTheFirstPhotoWithThatName() {
        let index = [legacy("IMG_0001_ig.jpg")]
        XCTAssertEqual(plan(["/t1/IMG_0001.jpg", "/t2/IMG_0001.jpg"], index),
                       [ExportEntry(name: "IMG_0001_ig.jpg", own: true), ExportEntry(name: "IMG_0001_ig-2.jpg", own: false)])
    }

    func testFilesOfOtherToolsAreLeftAlone() {
        XCTAssertEqual(plan(["/t1/IMG_0001.jpg"], [foreign("IMG_0001_ig.jpg")]),
                       [ExportEntry(name: "IMG_0001_ig-2.jpg", own: false)])
    }

    func testExportedFollowsThePlan() {
        let index = Dictionary(uniqueKeysWithValues: [ours("IMG_0001_ig-2.jpg", "/t2/IMG_0001.jpg"),
                                                      legacy("IMG_0005_ig.jpg")])
        // in the order of the photo strip: /z was added before /a
        let paths = ["/t2/IMG_0001.jpg", "/t1/IMG_0001.jpg", "/z/IMG_0005.jpg", "/a/IMG_0005.jpg", "/t1/IMG_0009.jpg"]
        let has = ExportPlan.exported(sources: paths.map(u), id: { self.id($0.path) }, index: index)
        XCTAssertEqual(has[u("/t2/IMG_0001.jpg")], true)
        XCTAssertEqual(has[u("/t1/IMG_0001.jpg")], false, "another photo's output is not this one's")
        XCTAssertEqual(has[u("/z/IMG_0005.jpg")], true, "an output from before 1.2 counts for the first photo in order")
        XCTAssertEqual(has[u("/a/IMG_0005.jpg")], false, "... and only for that one, as an export of both would use it")
        XCTAssertEqual(has[u("/t1/IMG_0009.jpg")], false)
    }

    func testIDsOnlyWhereTheFolderHasThatFamily() {
        var asked: [String] = []
        let index = Dictionary(uniqueKeysWithValues: [ours("IMG_0001_ig.jpg", "/t1/IMG_0001.jpg")])
        let e = ExportPlan.plan(sources: [u("/t1/IMG_0001.jpg"), u("/t1/IMG_0002.jpg")],
                                id: { asked.append($0.path); return self.id($0.path) }, index: index)
        XCTAssertEqual(asked, ["/t1/IMG_0001.jpg"], "no metadata read for a photo with nothing in the folder")
        XCTAssertEqual(e.map(\.own), [true, false])
        XCTAssertEqual(e[1].source, "", "worked out when it is written")
    }

    func testActions() {
        let own = ExportEntry(name: "a_ig.jpg", own: true), cut = ExportEntry(name: "a_ig.jpg", own: true, complete: false)
        let new = ExportEntry(name: "a_ig-2.jpg", own: false)
        XCTAssertEqual(ExportPlan.action(for: new, policy: .overwrite), .write)
        XCTAssertEqual(ExportPlan.action(for: own, policy: .overwrite), .overwrite)
        XCTAssertEqual(ExportPlan.action(for: own, policy: .rename), .copy)
        XCTAssertEqual(ExportPlan.action(for: own, policy: .skip), .skip)
        XCTAssertEqual(ExportPlan.action(for: own, policy: .ask), .skip)
        for p in ExistingFiles.allCases { XCTAssertEqual(ExportPlan.action(for: cut, policy: p), .overwrite, "\(p)") }
    }

    /// On a case-sensitive volume two outputs can differ only in case; both are kept apart, and new names never
    /// clash with either in case.
    func testNamesDifferingInCase() {
        let index = [ours("IMG_0001_ig.jpg", "/t1/IMG_0001.jpg"), ours("img_0001_ig.jpg", "/t2/img_0001.jpg")]
        XCTAssertEqual(plan(["/t2/img_0001.jpg", "/t1/IMG_0001.jpg", "/t3/IMG_0001.jpg"], index).map(\.name),
                       ["img_0001_ig.jpg", "IMG_0001_ig.jpg", "IMG_0001_ig-2.jpg"])
    }

    func testOwnOutputCutOffIsMarked() {
        let cut = ("IMG_0001_ig.jpg", OutputInfo(name: "IMG_0001_ig.jpg", signature: "0123456789abcdef",
                                                 source: id("/t1/IMG_0001.jpg"), complete: false))
        XCTAssertEqual(plan(["/t1/IMG_0001.jpg"], [cut]), [ExportEntry(name: "IMG_0001_ig.jpg", own: true, complete: false)])
    }

    // On disk: the source ID round trip, the folder scan and storeUnique.

    private func scratch() throws -> URL {
        let base = ProcessInfo.processInfo.environment["PHOTOLAB_TEST_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("photolab_names_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A JPEG with a capture time (and camera model), like a camera's or Lightroom's.
    private static func photo(at url: URL, taken: String, model: String = "TEST-1") throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: model]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The review's case: the same photo after its folder is renamed or the disk mounts under another name keeps
    /// its ID; a different photo with the same file name does not share it.
    func testSourceIDFollowsThePhotoNotThePath() throws {
        let dir = try scratch()
        for d in ["trip", "trip renamed", "other"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let a = dir.appendingPathComponent("trip/IMG_0001.jpg"), moved = dir.appendingPathComponent("trip renamed/IMG_0001.jpg")
        let other = dir.appendingPathComponent("other/IMG_0001.jpg")
        try Self.photo(at: a, taken: "2024:01:02 10:00:00")
        try Self.photo(at: moved, taken: "2024:01:02 10:00:00")
        try Self.photo(at: other, taken: "2025:06:07 08:09:10")
        XCTAssertEqual(OutputSignature.sourceID(for: a, key: key), OutputSignature.sourceID(for: moved, key: key))
        XCTAssertNotEqual(OutputSignature.sourceID(for: a, key: key), OutputSignature.sourceID(for: other, key: key))
        let noExif = dir.appendingPathComponent("trip/plain.jpg")
        try Self.jpeg(source: nil).write(to: noExif)
        XCTAssertTrue(OutputSignature.identity(of: noExif).hasPrefix("path"), "no capture time: by path")
        XCTAssertTrue(OutputSignature.identity(of: a).hasPrefix("capture"))
    }

    private static func jpeg(source: String?) throws -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return try Renderer.encodeJPEG(ctx.makeImage()!, quality: 0.9, signature: "0123456789abcdef", source: source)
    }

    func testScanReadsSourceIDs() throws {
        let dir = try scratch()
        try Self.jpeg(source: id("/t2/IMG_0001.jpg")).write(to: dir.appendingPathComponent("IMG_0001_ig-2.jpg"))
        try Self.jpeg(source: nil).write(to: dir.appendingPathComponent("IMG_0001_ig.jpg"))
        try Data("not a jpeg".utf8).write(to: dir.appendingPathComponent("IMG_0001_ig-3.jpg"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("other.jpg"))
        let index = ExportPlan.scan(dir, stems: ["img_0001_ig"])
        XCTAssertEqual(Set(index.keys), ["IMG_0001_ig.jpg", "IMG_0001_ig-2.jpg", "IMG_0001_ig-3.jpg"])
        XCTAssertEqual(index["IMG_0001_ig-2.jpg"]?.source, id("/t2/IMG_0001.jpg"))
        XCTAssertEqual(index["IMG_0001_ig-2.jpg"]?.signature, "0123456789abcdef")
        XCTAssertEqual(index["IMG_0001_ig-2.jpg"]?.complete, true)
        XCTAssertNil(index["IMG_0001_ig.jpg"]?.source)
        XCTAssertNotNil(index["IMG_0001_ig.jpg"]?.signature)
        XCTAssertNil(index["IMG_0001_ig-3.jpg"]?.signature, "a file of another tool")
        XCTAssertEqual(OutputSignature.existing(at: dir.appendingPathComponent("IMG_0001_ig-2.jpg")), "0123456789abcdef")
    }

    /// A FIFO or a symlink under an output name must not stall or mislead the scan: no Photo_Lab output there.
    /// On APFS (exFAT has no FIFOs).
    func testScanSkipsSpecialFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photolab_fifo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Self.jpeg(source: id("/t1/IMG_0001.jpg")).write(to: dir.appendingPathComponent("real.jpg"))
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("IMG_0001_ig.jpg").path, 0o644), 0)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("IMG_0001_ig-2.jpg"),
                                                   withDestinationURL: dir.appendingPathComponent("real.jpg"))
        let start = Date()
        let index = ExportPlan.scan(dir, stems: ["img_0001_ig"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "did not block on the FIFO")
        XCTAssertNil(index["IMG_0001_ig.jpg"]?.signature)
        XCTAssertNil(index["IMG_0001_ig-2.jpg"]?.source, "a symlink is not followed")
        XCTAssertEqual(plan(["/t1/IMG_0001.jpg"], Array(index)).map(\.name), ["IMG_0001_ig-3.jpg"],
                       "both names stay taken, nothing is replaced")
    }

    func testStoreUniqueTakesTheNextFreeNumber() throws {
        let dir = try scratch()
        let base = dir.appendingPathComponent("a_ig.jpg")
        try Data("old".utf8).write(to: base)
        try Data("old2".utf8).write(to: dir.appendingPathComponent("a_ig-2.jpg"))
        let written = try Renderer.storeUnique(Data("new".utf8), base: base, reserved: [])
        XCTAssertEqual(written.lastPathComponent, "a_ig-3.jpg")
        XCTAssertEqual(try Data(contentsOf: written), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: base), Data("old".utf8), "existing files are left alone")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a_ig-2.jpg")), Data("old2".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["a_ig-2.jpg", "a_ig-3.jpg", "a_ig.jpg"], "no temp files left")
    }

    func testStoreUniqueFromThePlainName() throws {
        let dir = try scratch()
        let base = dir.appendingPathComponent("a_ig.jpg")
        XCTAssertEqual(try Renderer.storeUnique(Data("new".utf8), base: base, first: 1, reserved: []), base)
    }

    func testStoreUniqueSkipsNamesOfTheSameExport() throws {
        let dir = try scratch()
        let base = dir.appendingPathComponent("a_ig.jpg")
        try Data("old".utf8).write(to: base)
        let written = try Renderer.storeUnique(Data("new".utf8), base: base, reserved: ["a_ig.jpg", "a_ig-2.jpg"])
        XCTAssertEqual(written.lastPathComponent, "a_ig-3.jpg")
    }

    func testStoreUniqueGivesUpAfterTheLimit() throws {
        let dir = try scratch()
        let base = dir.appendingPathComponent("a_ig.jpg")
        for n in 2...3 { try Data("x".utf8).write(to: dir.appendingPathComponent("a_ig-\(n).jpg")) }
        XCTAssertThrowsError(try Renderer.storeUnique(Data("new".utf8), base: base, reserved: [], limit: 3)) {
            guard case RenderError.exists = $0 else { return XCTFail("expected .exists, got \($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["a_ig-2.jpg", "a_ig-3.jpg"], "no temp file left")
    }
}
