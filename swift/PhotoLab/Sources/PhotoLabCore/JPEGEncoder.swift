import CoreGraphics
import Foundation

/// A baseline JPEG encoder with full-resolution chroma (4:4:4), like the Python renderer's output. ImageIO has no
/// public switch for chroma subsampling and writes 4:2:0, which softens thin coloured text and logos. Standard
/// Huffman tables and the IJG quality scaling, so quality 95 here is quality 95 there.
enum JPEGEncoder {
    static let dcLum: (bits: [UInt8], values: [UInt8]) = (
        [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    static let acLum: (bits: [UInt8], values: [UInt8]) = (
        [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125],
        [1, 2, 3, 0, 4, 17, 5, 18, 33, 49, 65, 6, 19, 81, 97, 7, 34, 113, 20, 50, 129, 145, 161, 8, 35, 66, 177, 193, 21, 82, 209, 240, 36, 51, 98, 114, 130, 9, 10, 22, 23, 24, 25, 26, 37, 38, 39, 40, 41, 42, 52, 53, 54, 55, 56, 57, 58, 67, 68, 69, 70, 71, 72, 73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105, 106, 115, 116, 117, 118, 119, 120, 121, 122, 131, 132, 133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153, 154, 162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179, 180, 181, 182, 183, 184, 185, 186, 194, 195, 196, 197, 198, 199, 200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250])
    static let dcChroma: (bits: [UInt8], values: [UInt8]) = (
        [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    static let acChroma: (bits: [UInt8], values: [UInt8]) = (
        [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119],
        [0, 1, 2, 3, 17, 4, 5, 33, 49, 6, 18, 65, 81, 7, 97, 113, 19, 34, 50, 129, 8, 20, 66, 145, 161, 177, 193, 9, 35, 51, 82, 240, 21, 98, 114, 209, 10, 22, 36, 52, 225, 37, 241, 23, 24, 25, 26, 38, 39, 40, 41, 42, 53, 54, 55, 56, 57, 58, 67, 68, 69, 70, 71, 72, 73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105, 106, 115, 116, 117, 118, 119, 120, 121, 122, 130, 131, 132, 133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153, 154, 162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179, 180, 181, 182, 183, 184, 185, 186, 194, 195, 196, 197, 198, 199, 200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218, 226, 227, 228, 229, 230, 231, 232, 233, 234, 242, 243, 244, 245, 246, 247, 248, 249, 250])

    static let lumQuant: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29,
        51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121,
        120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
    static let chromaQuant: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99,
        99, 99, 99, 99] + [Int](repeating: 99, count: 32)
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
        21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53,
        60, 61, 54, 47, 55, 62, 63]

    /// Orthonormal 8-point DCT matrix: row u, column x.
    static let dctMatrix: [SIMD8<Float>] = (0..<8).map { u in
        SIMD8<Float>((0..<8).map { x in
            let a: Double = u == 0 ? (1.0 / 8.0).squareRoot() : 0.5
            return Float(a * cos(Double(2 * x + 1) * Double(u) * Double.pi / 16))
        })
    }

    struct HuffCode { var code: UInt16 = 0; var size: UInt8 = 0 }

    static func buildCodes(_ t: (bits: [UInt8], values: [UInt8])) -> [HuffCode] {
        var codes = [HuffCode](repeating: HuffCode(), count: 256)
        var code: UInt16 = 0, k = 0
        for len in 1...16 {
            for _ in 0..<Int(t.bits[len - 1]) {
                codes[Int(t.values[k])] = HuffCode(code: code, size: UInt8(len))
                code += 1; k += 1
            }
            code <<= 1
        }
        return codes
    }

    static func scaledTable(_ base: [Int], quality: Int) -> [Int] {
        let q = min(100, max(1, quality))
        let scale = q < 50 ? 5000 / q : 200 - q * 2
        return base.map { min(255, max(1, ($0 * scale + 50) / 100)) }
    }

    /// 8x8 float block (rows as SIMD8) -> DCT coefficients, row-major.
    @inline(__always)
    static func fdct(_ rows: inout [SIMD8<Float>]) {
        // vertical: T[u] = sum_x C[u][x] * rows[x]  (a SIMD8 over the 8 columns)
        var t = [SIMD8<Float>](repeating: .zero, count: 8)
        for u in 0..<8 {
            var acc = SIMD8<Float>.zero
            let c = dctMatrix[u]
            for x in 0..<8 { acc += rows[x] * c[x] }
            t[u] = acc
        }
        // horizontal: out[u][v] = sum_x T[u][x] * C[v][x]
        for u in 0..<8 {
            var o = SIMD8<Float>.zero
            for v in 0..<8 { o[v] = (t[u] * dctMatrix[v]).sum() }
            rows[u] = o
        }
    }

    // MARK: bit writer

    struct BitWriter {
        var bytes = [UInt8]()
        var acc: UInt32 = 0
        var nbits = 0

        mutating func put(_ code: UInt16, _ size: Int) {
            guard size > 0 else { return }
            acc = (acc << UInt32(size)) | UInt32(code) & ((1 << UInt32(size)) - 1)
            nbits += size
            while nbits >= 8 {
                let b = UInt8((acc >> UInt32(nbits - 8)) & 0xFF)
                bytes.append(b)
                if b == 0xFF { bytes.append(0) }
                nbits -= 8
            }
            acc &= (1 << UInt32(nbits)) - 1
        }

        mutating func flush() {
            if nbits > 0 { put(0x7F, 8 - nbits) }        // pad with 1 bits
        }
    }

    // MARK: encode

    /// `quality` 1...100. `comment` becomes a COM segment. The colour profile of `image` is embedded.
    static func encode(_ image: CGImage, quality: Int, comment: String?) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 65_535, h <= 65_535, let space = image.colorSpace else { return nil }
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let qLum = scaledTable(lumQuant, quality: quality), qChroma = scaledTable(chromaQuant, quality: quality)
        let invLum = qLum.map { 1 / Float($0) }, invChroma = qChroma.map { 1 / Float($0) }
        let dcL = buildCodes(dcLum), acL = buildCodes(acLum), dcC = buildCodes(dcChroma), acC = buildCodes(acChroma)

        var out = Data()
        func marker(_ m: UInt8, _ payload: [UInt8]) {
            out.append(contentsOf: [0xFF, m, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)])
            out.append(contentsOf: payload)
        }
        out.append(contentsOf: [0xFF, 0xD8])
        marker(0xE0, [0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0])           // JFIF 1.01, 1:1 aspect
        if let comment, !comment.isEmpty, comment.utf8.count < 60_000 { marker(0xFE, Array(comment.utf8)) }
        if let icc = space.copyICCData() as Data?, !icc.isEmpty {
            let chunk = 65_519 - 14
            let count = (icc.count + chunk - 1) / chunk
            if count < 255 {
                for i in 0..<count {
                    let part = icc.subdata(in: (i * chunk)..<min(icc.count, (i + 1) * chunk))
                    marker(0xE2, Array("ICC_PROFILE".utf8) + [0, UInt8(i + 1), UInt8(count)] + Array(part))
                }
            }
        }
        marker(0xDB, [0] + zigzag.map { UInt8(qLum[$0]) })
        marker(0xDB, [1] + zigzag.map { UInt8(qChroma[$0]) })
        marker(0xC0, [8, UInt8(h >> 8), UInt8(h & 255), UInt8(w >> 8), UInt8(w & 255), 3,
                      1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1])
        for (cls, t) in [(0x00, dcLum), (0x10, acLum), (0x01, dcChroma), (0x11, acChroma)] as [(UInt8, (bits: [UInt8], values: [UInt8]))] {
            marker(0xC4, [cls] + t.bits + t.values)
        }
        marker(0xDA, [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0])

        let bw = (w + 7) / 8, bh = (h + 7) / 8
        var writer = BitWriter()
        writer.bytes.reserveCapacity(w * h / 3)
        var lastDC = [Int](repeating: 0, count: 3)

        // batches of block rows: transform in parallel, entropy-code in order
        let batch = 16
        var row0 = 0
        while row0 < bh {
            let rows = min(batch, bh - row0)
            var coeffs = [Int16](repeating: 0, count: rows * bw * 3 * 64)
            coeffs.withUnsafeMutableBufferPointer { cbuf in
                let base = cbuf.baseAddress!
                pixels.withUnsafeBufferPointer { pbuf in
                    let p = pbuf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: rows) { r in
                        let by = row0 + r
                        var block = [SIMD8<Float>](repeating: .zero, count: 8)
                        for bx in 0..<bw {
                            for comp in 0..<3 {
                                for y in 0..<8 {
                                    let sy = min(h - 1, by * 8 + y)
                                    var rowv = SIMD8<Float>.zero
                                    for x in 0..<8 {
                                        let sx = min(w - 1, bx * 8 + x)
                                        let i = sy * bytesPerRow + sx * 4
                                        let rr = Float(p[i]), gg = Float(p[i + 1]), bb = Float(p[i + 2])
                                        let v: Float
                                        switch comp {
                                        case 0: v = 0.299 * rr + 0.587 * gg + 0.114 * bb
                                        case 1: v = -0.168736 * rr - 0.331264 * gg + 0.5 * bb + 128
                                        default: v = 0.5 * rr - 0.418688 * gg - 0.081312 * bb + 128
                                        }
                                        rowv[x] = v - 128
                                    }
                                    block[y] = rowv
                                }
                                fdct(&block)
                                let inv = comp == 0 ? invLum : invChroma
                                let dst = base + ((r * bw + bx) * 3 + comp) * 64
                                for k in 0..<64 {
                                    let pos = zigzag[k]
                                    let v = block[pos >> 3][pos & 7] * inv[pos]
                                    dst[k] = Int16(max(-32767, min(32767, v.rounded())))
                                }
                            }
                        }
                    }
                }
            }
            for r in 0..<rows {
                for bx in 0..<bw {
                    for comp in 0..<3 {
                        let off = ((r * bw + bx) * 3 + comp) * 64
                        let dc = comp == 0 ? dcL : dcC, ac = comp == 0 ? acL : acC
                        let diff = Int(coeffs[off]) - lastDC[comp]
                        lastDC[comp] = Int(coeffs[off])
                        let (cat, bits) = magnitude(diff)
                        writer.put(dc[cat].code, Int(dc[cat].size))
                        writer.put(UInt16(bits), cat)
                        var run = 0
                        for k in 1..<64 {
                            let v = Int(coeffs[off + k])
                            if v == 0 { run += 1; continue }
                            while run > 15 {
                                writer.put(ac[0xF0].code, Int(ac[0xF0].size))
                                run -= 16
                            }
                            let (c, b) = magnitude(v)
                            let sym = (run << 4) | c
                            writer.put(ac[sym].code, Int(ac[sym].size))
                            writer.put(UInt16(b), c)
                            run = 0
                        }
                        if run > 0 { writer.put(ac[0].code, Int(ac[0].size)) }
                    }
                }
            }
            row0 += rows
        }
        writer.flush()
        out.append(contentsOf: writer.bytes)
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    /// (size category, the bits to write) of a coefficient.
    @inline(__always)
    static func magnitude(_ v: Int) -> (Int, Int) {
        if v == 0 { return (0, 0) }
        let a = abs(v)
        let cat = Int.bitWidth - a.leadingZeroBitCount
        return (cat, v < 0 ? (v - 1) & ((1 << cat) - 1) : v)
    }
}
