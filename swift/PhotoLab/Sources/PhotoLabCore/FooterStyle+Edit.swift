import Foundation

/// The editing operations of the style editor (drag and drop), kept here so they can be tested without the UI.
/// Every operation validates its arguments and returns false, leaving the style untouched, when it cannot be done.
extension FooterStyle {
    public static let blockNames = ["left", "center", "right"]

    public mutating func setBlock(_ name: String, _ b: StyleBlock) {
        switch name {
        case "left": left = b
        case "right": right = b
        default: center = b
        }
    }

    /// Old styles carried the focal length inside the exposure element; it is an element of its own now. Puts a
    /// 焦距 element in front of each 拍攝參數 (once; nothing happens when the style already has one).
    public mutating func splitFocal() {
        let all = [left, center, right]
        guard !all.contains(where: { $0.lines.contains { $0.items.contains("focal") } }) else { return }
        for name in FooterStyle.blockNames {
            var b = block(name)
            for i in b.lines.indices {
                var out: [String] = []
                for t in b.lines[i].items { if t == "exposure" { out.append("focal") }; out.append(t) }
                b.lines[i].items = Array(out.prefix(FooterStyle.maxItems))
            }
            setBlock(name, b)
        }
    }

    private func hasLine(_ block: String, _ line: Int) -> Bool {
        FooterStyle.blockNames.contains(block) && self.block(block).lines.indices.contains(line)
    }

    /// Inserts a new element (from the tray) before `before`, or at the end when it is nil.
    public mutating func insertItem(_ token: String, block: String, line: Int, before: Int?) -> Bool {
        guard FooterStyle.tokens.contains(token), hasLine(block, line) else { return false }
        var b = self.block(block)
        guard b.lines[line].items.count < FooterStyle.maxItems else { return false }
        let at = min(max(before ?? b.lines[line].items.count, 0), b.lines[line].items.count)
        b.lines[line].items.insert(token, at: at)
        setBlock(block, b)
        return true
    }

    public mutating func removeItem(block: String, line: Int, index: Int) -> Bool {
        guard hasLine(block, line), self.block(block).lines[line].items.indices.contains(index) else { return false }
        var b = self.block(block)
        b.lines[line].items.remove(at: index)
        setBlock(block, b)
        return true
    }

    /// Moves a placed element so that it ends up before the element that is at `before` now (nil = the end of the
    /// line). Moving within one line is the common case: the result is what the insertion bar showed.
    public mutating func moveItem(fromBlock: String, line fromLine: Int, index: Int,
                                  toBlock: String, line toLine: Int, before: Int?) -> Bool {
        guard hasLine(fromBlock, fromLine), hasLine(toBlock, toLine),
              self.block(fromBlock).lines[fromLine].items.indices.contains(index) else { return false }
        let same = fromBlock == toBlock && fromLine == toLine
        if !same && self.block(toBlock).lines[toLine].items.count >= FooterStyle.maxItems { return false }
        let token = self.block(fromBlock).lines[fromLine].items[index]
        var target = before ?? Int.max           // position in the line as it is *before* the removal
        if same, before == index || before == index + 1 { return true }          // dropped where it already is
        _ = removeItem(block: fromBlock, line: fromLine, index: index)
        if same, target != Int.max, index < target { target -= 1 }               // the removal shifted the target
        let count = self.block(toBlock).lines[toLine].items.count
        return insertItem(token, block: toBlock, line: toLine, before: target == Int.max ? count : min(target, count))
    }

    /// Swaps the contents of two blocks (lines and logo flags); each position keeps its own alignment.
    public mutating func swapBlocks(_ a: String, _ b: String) -> Bool {
        guard a != b, FooterStyle.blockNames.contains(a), FooterStyle.blockNames.contains(b) else { return false }
        var x = block(a), y = block(b)
        swap(&x.lines, &y.lines)
        swap(&x.logo, &y.logo)
        swap(&x.logoRule, &y.logoRule)
        setBlock(a, x)
        setBlock(b, y)
        return true
    }
}
