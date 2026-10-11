import Foundation
import PhotoLabCore

// photolab-render <input> <output.jpg> [--ratio 4:5] [--thickness 10] [--style white|rounded|blur|blur_square]
//                 [--corner 0.012] [--quality 95] [--footer options.json] [--logos DIR] [--fonts DIR]
// --footer reads the footer options by the names the Python renderer uses (footer, footer_layout, footer_fields ...).
// Development tool: renders one photo with the border settings, to compare against the Python renderer.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("photolab-render: " + message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail("usage: photolab-render <input> <output.jpg> [--ratio R] [--thickness N] [--style S] [--corner F] [--quality Q]") }
let input = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
let output = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
guard input != output else { fail("output must not be the input file") }
do {   // the same file reached by another name (hard link, different case on a case-insensitive volume)
    var a = stat(), b = stat()
    if stat(input.path, &a) == 0, stat(output.path, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino {
        fail("output must not be the input file")
    }
}
guard ["jpg", "jpeg"].contains(output.pathExtension.lowercased()) else { fail("output must be a .jpg file") }

var opts = RenderOptions()
var footerFile: URL?
var logosDir = URL(fileURLWithPath: "logos", isDirectory: true)
var fontsDir = URL(fileURLWithPath: "fonts", isDirectory: true)
while !args.isEmpty {
    let key = args.removeFirst()
    guard !args.isEmpty else { fail("missing value for \(key)") }
    let value = args.removeFirst()
    switch key {
    case "--ratio":
        guard let r = Ratio(value) else { fail("unknown ratio") }
        opts.ratio = r
    case "--thickness":
        guard let v = Double(value), v >= 0, v <= 50 else { fail("thickness must be 0...50") }
        opts.thickness = v
    case "--style":
        guard let s = FrameStyle(rawValue: value) else { fail("unknown style") }
        opts.style = s
    case "--corner":
        guard let v = Double(value), v >= 0.001, v <= 0.08 else { fail("corner must be 0.001...0.08") }
        opts.corner = v
    case "--quality":
        guard let v = Double(value), v >= 1, v <= 100 else { fail("quality must be 1...100") }
        opts.quality = v / 100
    case "--footer":
        footerFile = URL(fileURLWithPath: value)
    case "--logos":
        logosDir = URL(fileURLWithPath: value, isDirectory: true)
    case "--fonts":
        fontsDir = URL(fileURLWithPath: value, isDirectory: true)
    default:
        fail("unknown option \(key)")
    }
}

do {
    let photo = try Renderer.load(url: input)
    var footer: FooterSpec?
    let resources = Resources(logosDir: logosDir, fontsDir: fontsDir)
    if let footerFile {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: footerFile.path),
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 200_000,
              let data = try? Data(contentsOf: footerFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("cannot read the footer options file")
        }
        footer = FooterSpec(options: json, info: ExifReader.read(url: input), resources: resources)
    }
    let canvas = try Renderer.render(photo, options: opts, footer: footer, resources: resources)
    try Renderer.saveJPEG(canvas, to: output, quality: opts.quality)
    print("done: \(input.lastPathComponent) -> \(output.lastPathComponent) (\(canvas.width)x\(canvas.height))")
} catch {
    fail("\(error)")
}
