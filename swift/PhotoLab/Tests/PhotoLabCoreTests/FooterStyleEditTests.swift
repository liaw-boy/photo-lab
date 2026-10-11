import XCTest
@testable import PhotoLabCore

final class FooterStyleEditTests: XCTestCase {
    private func style() -> FooterStyle {
        var s = FooterStyle.default
        s.setBlock("left", StyleBlock(align: "left", lines: [StyleLine(items: ["logo", "model_auto", "lens"]),
                                                              StyleLine(items: ["date"])]))
        s.setBlock("center", StyleBlock(align: "center", lines: []))
        s.setBlock("right", StyleBlock(align: "right", lines: [StyleLine(items: ["exposure"])]))
        return s
    }
    private func items(_ s: FooterStyle, _ b: String, _ l: Int) -> [String] { s.block(b).lines[l].items }

    func testMoveRightWithinLine() {            // the reported case: model -> after lens
        var s = style()
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 1, toBlock: "left", line: 0, before: nil))
        XCTAssertEqual(items(s, "left", 0), ["logo", "lens", "model_auto"])
    }
    func testMoveBeforeNextButOne() {
        var s = style()
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 0, toBlock: "left", line: 0, before: 2))
        XCTAssertEqual(items(s, "left", 0), ["model_auto", "logo", "lens"])
    }
    func testMoveLeft() {
        var s = style()
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 2, toBlock: "left", line: 0, before: 0))
        XCTAssertEqual(items(s, "left", 0), ["lens", "logo", "model_auto"])
    }
    func testDropOnItselfOrNeighbourSlotKeepsOrder() {
        var s = style()
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 1, toBlock: "left", line: 0, before: 1))
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 1, toBlock: "left", line: 0, before: 2))
        XCTAssertEqual(items(s, "left", 0), ["logo", "model_auto", "lens"])
    }
    func testMoveLastToEndKeepsOrder() {
        var s = style()
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 2, toBlock: "left", line: 0, before: nil))
        XCTAssertEqual(items(s, "left", 0), ["logo", "model_auto", "lens"])
    }
    func testMoveAcrossLinesAndBlocks() {
        var s = style()
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 0, index: 2, toBlock: "left", line: 1, before: 0))
        XCTAssertEqual(items(s, "left", 0), ["logo", "model_auto"])
        XCTAssertEqual(items(s, "left", 1), ["lens", "date"])
        XCTAssertTrue(s.moveItem(fromBlock: "left", line: 1, index: 1, toBlock: "right", line: 0, before: nil))
        XCTAssertEqual(items(s, "right", 0), ["exposure", "date"])
    }
    func testFullLineRejectsForeignItem() {
        var s = style()
        s.setBlock("right", StyleBlock(align: "right", lines: [StyleLine(items: Array(repeating: "lens",
                                                                                     count: FooterStyle.maxItems))]))
        XCTAssertFalse(s.moveItem(fromBlock: "left", line: 0, index: 0, toBlock: "right", line: 0, before: nil))
        XCTAssertEqual(items(s, "left", 0).count, 3)
        XCTAssertFalse(s.insertItem("date", block: "right", line: 0, before: nil))
    }
    func testInsertAndRemove() {
        var s = style()
        XCTAssertTrue(s.insertItem("custom", block: "left", line: 1, before: 0))
        XCTAssertEqual(items(s, "left", 1), ["custom", "date"])
        XCTAssertTrue(s.removeItem(block: "left", line: 1, index: 0))
        XCTAssertEqual(items(s, "left", 1), ["date"])
    }
    func testInvalidInputIsRejected() {
        var s = style()
        let before = s
        XCTAssertFalse(s.insertItem("../etc", block: "left", line: 0, before: nil))
        XCTAssertFalse(s.insertItem("date", block: "top", line: 0, before: nil))
        XCTAssertFalse(s.insertItem("date", block: "left", line: 9, before: nil))
        XCTAssertFalse(s.removeItem(block: "left", line: 0, index: 9))
        XCTAssertFalse(s.moveItem(fromBlock: "left", line: 0, index: -1, toBlock: "left", line: 0, before: 0))
        XCTAssertEqual(s, before)
    }
    func testSwapBlocksKeepsAlignmentOfPosition() {
        var s = style()
        XCTAssertTrue(s.swapBlocks("left", "right"))
        XCTAssertEqual(items(s, "right", 0), ["logo", "model_auto", "lens"])
        XCTAssertEqual(items(s, "left", 0), ["exposure"])
        XCTAssertEqual(s.block("left").align, "left")
        XCTAssertEqual(s.block("right").align, "right")
        XCTAssertFalse(s.swapBlocks("left", "left"))
    }
}
