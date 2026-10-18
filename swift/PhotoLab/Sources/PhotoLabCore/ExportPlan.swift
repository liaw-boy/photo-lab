import Foundation

/// What Photo_Lab wrote into one output file (see `OutputSignature.read`).
public struct OutputInfo: Equatable, Sendable {
    public let name: String            // the file name as it is on disk
    public let signature: String?
    public let source: String?         // `OutputSignature.sourceID`; nil for outputs made before 1.2
    public let complete: Bool          // ends with the JPEG end marker

    public init(name: String, signature: String?, source: String?, complete: Bool) {
        self.name = name
        self.signature = signature
        self.source = source
        self.complete = complete
    }
}

/// What an export does with a photo's own earlier output (Lightroom's 既有檔案).
public enum ExistingFiles: String, CaseIterable, Sendable {
    case ask, rename, overwrite, skip
}

/// What the export does for one photo.
public enum ExportAction: Equatable, Sendable {
    case write          // a new output, at the planned name (or the next free number if it is taken since)
    case overwrite      // replace its own earlier output
    case copy           // keep its own earlier output, add a numbered copy (自動改名)
    case skip           // keep its own earlier output, do nothing
}

/// Where one photo of an export goes.
public struct ExportEntry: Equatable, Sendable {
    public let name: String            // output file name
    public let own: Bool               // that file is this photo's own earlier output (既有檔案 applies to it)
    public let complete: Bool          // for an own output: it was written to the end (not cut off)
    public let source: String          // the photo's source ID, to write into the output

    public init(name: String, own: Bool, complete: Bool = true, source: String = "") {
        self.name = name
        self.own = own
        self.complete = complete
        self.source = source
    }
}

/// Output names that know their source. Each output carries the ID of the photo it was made from, so a photo's
/// earlier output is found among `a_ig.jpg`, `a_ig-2.jpg` ... whatever was selected then or now, and a file that
/// belongs to another photo with the same name is never taken for it: the new output gets the next free number.
public enum ExportPlan {
    /// `a_ig.jpg` -> ("a_ig", 1), `A_IG-3.jpg` -> ("a_ig", 3) (lower-cased); nil for names that are no output name.
    public static func family(of name: String) -> (stem: String, number: Int)? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".jpg") else { return nil }
        let stem = String(lower.dropLast(4))
        if stem.hasSuffix("_ig") { return (stem, 1) }
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let head = String(stem[..<dash]), digits = stem[stem.index(after: dash)...]
        guard head.hasSuffix("_ig"), !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII),
              let n = Int(digits), n >= 2, String(n) == digits else { return nil }
        return (head, n)
    }

    /// The Photo_Lab outputs in `dir` that belong to one of `stems` (see `family`), by file name as on disk.
    /// One directory listing, and a few KB read from each matching file. Any file there takes up its name; a file
    /// of another tool simply has no signature and no source.
    public static func scan(_ dir: URL, stems: Set<String>) -> [String: OutputInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: OutputInfo] = [:]
        for name in names where !name.hasPrefix(".") {
            guard let f = family(of: name), stems.contains(f.stem) else { continue }
            out[name] = OutputSignature.read(at: dir.appendingPathComponent(name))
                ?? OutputInfo(name: name, signature: nil, source: nil, complete: false)
        }
        return out
    }

    /// The stem of a photo's output family.
    public static func stem(for source: URL) -> String {
        family(of: Files.outputName(for: source))!.stem
    }

    /// The action for each planned photo under `policy` (.ask means the answer is still to come: treated as skip).
    /// An own output cut off while written (exFAT) is always written again: it is no output to keep.
    public static func action(for e: ExportEntry, policy: ExistingFiles) -> ExportAction {
        guard e.own else { return .write }
        guard e.complete else { return .overwrite }
        switch policy {
        case .overwrite: return .overwrite
        case .rename: return .copy
        case .skip, .ask: return .skip
        }
    }

    /// Output names for one export, in order. A photo gets its own earlier output when there is one (the file in
    /// its family with its source ID; an output from before 1.2, which has no ID, counts for the first photo of
    /// the export with that plain name, as names worked then). Otherwise it gets the first name of its family that
    /// is neither on disk nor given to another photo of this export. Names are compared without case, as the
    /// usual volumes do, so two names differing only in case are never handed out.
    public static func plan(sources: [URL], ids: [String], index: [String: OutputInfo]) -> [ExportEntry] {
        let byURL = Dictionary(zip(sources, ids), uniquingKeysWith: { a, _ in a })
        return plan(sources: sources, id: { byURL[$0] ?? "" }, index: index)
    }

    /// The same, with source IDs worked out only for photos whose family has files in the folder (an ID reads the
    /// photo's metadata); the others get an empty `source`, to be worked out when they are written.
    public static func plan(sources: [URL], id: (URL) -> String, index: [String: OutputInfo]) -> [ExportEntry] {
        var claimed = Set<String>()                                 // own outputs given out, by exact name
        var taken = Set<String>()                                   // every name given out, lower-cased
        let onDisk = Set(index.keys.map { $0.lowercased() })
        var byStem: [String: [(n: Int, info: OutputInfo)]] = [:]
        for (name, info) in index {
            if let f = family(of: name) { byStem[f.stem, default: []].append((f.number, info)) }
        }
        for k in byStem.keys { byStem[k]!.sort { ($0.n, $0.info.name) < ($1.n, $1.info.name) } }
        return sources.map { src in
            let base = Files.outputName(for: src)
            let members = byStem[family(of: base)!.stem] ?? []
            let id = members.contains { $0.info.source != nil } ? id(src) : ""
            // An existing file is one file, whatever other names differ from it only in case; a new name must
            // not clash in case with anything.
            let free = { (info: OutputInfo) in !claimed.contains(info.name) }
            if let mine = members.first(where: { !id.isEmpty && $0.info.source == id && free($0.info) })
                ?? members.first(where: { $0.n == 1 && $0.info.signature != nil && $0.info.source == nil
                                          && free($0.info) }) {
                claimed.insert(mine.info.name)
                taken.insert(mine.info.name.lowercased())
                return ExportEntry(name: mine.info.name, own: true, complete: mine.info.complete, source: id)
            }
            var n = 1
            while true {
                let name = n == 1 ? base : Files.numberedName(base, n)
                let key = name.lowercased()
                if !onDisk.contains(key) && !taken.contains(key) {
                    taken.insert(key)
                    return ExportEntry(name: name, own: false, source: id)
                }
                n += 1
            }
        }
    }

    /// Which of `sources` already have their own output in the scanned folder (for the 已輸出 counts): `plan` over
    /// them in the given order, which should be the order the photo strip lists them in, so the counts agree with
    /// what an export of all of them does (an output from before 1.2 counts for the first photo with its name).
    public static func exported(sources: [URL], id: (URL) -> String, index: [String: OutputInfo]) -> [URL: Bool] {
        var out: [URL: Bool] = [:]
        for (src, e) in zip(sources, plan(sources: sources, id: id, index: index)) where out[src] == nil {
            out[src] = e.own
        }
        return out
    }
}
