import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)       // a plain executable (swift run) is not a "regular" app by itself
        NSApp.activate(ignoringOtherApps: true)
        if let icon = NSImage(contentsOf: AppPaths.iconURL()) {
            NSApp.applicationIconImage = icon           // the same icon as the Python version
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    /// `PhotoLab [--output DIR] [--demo-footer] <folder or photos...>`: opens them (existing paths only).
    private func openLaunchArguments() {
        var args = Array(CommandLine.arguments.dropFirst())
        var urls: [URL] = []
        while !args.isEmpty {
            let a = args.removeFirst()
            if a == "--demo-footer" { model.settings.footerOn = true }
            else if a == "--output", !args.isEmpty {
                model.outputDir = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
            } else if !a.hasPrefix("-"), FileManager.default.fileExists(atPath: a) {
                urls.append(URL(fileURLWithPath: a))
            }
        }
        if !urls.isEmpty { model.add(urls: urls) } else { model.reloadPhotos() }
        model.refreshCounts()
    }

    /// Light by default (also on a dark system); 外觀 menu: 淺色 / 深色 / 跟隨系統.
    private var scheme: ColorScheme? {
        switch model.appearance {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }

    var body: some Scene {
        WindowGroup("Photo_Lab") {
            ContentView(model: model)
                .preferredColorScheme(scheme)
                .onAppear { openLaunchArguments() }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandMenu("外觀") {
                Picker("外觀", selection: $model.appearance) {
                    Text("淺色").tag("light")
                    Text("深色").tag("dark")
                    Text("跟隨系統").tag("system")
                }
                .pickerStyle(.inline)
            }
            CommandGroup(replacing: .help) {
                Button("自備品牌 logo 與字體…") { LogoHelp.show() }
            }
        }

        Window("樣式編輯器", id: "style-editor") {
            StyleEditorView(model: model)
                .preferredColorScheme(scheme)
        }
        .defaultSize(width: 1180, height: 700)
    }
}

/// Brand logos and fonts are not shipped (trademarks / licences): this tells where to put them and opens the folder.
@MainActor
enum LogoHelp {
    private static func folder(_ name: String) -> URL {
        let fm = FileManager.default
        let res = AppPaths.resources()
        let wanted = name == "logos" ? res.logosDir : res.fontsDir
        // never point into the app bundle itself: use the user's Application Support folder there
        if wanted.path.hasPrefix(Bundle.main.bundleURL.path + "/") {
            return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photo_Lab").appendingPathComponent(name)
        }
        return wanted
    }

    static func show() {
        let logos = folder("logos"), fonts = folder("fonts")
        let alert = NSAlert()
        alert.messageText = "自備品牌 logo 與字體"
        alert.informativeText = """
        品牌 logo 與字體因商標與授權不內含，請放進下面的資料夾：

        logo：\(logos.path)
        字體：\(fonts.path)

        logo 要求：
        • PNG、背景透明、深色 logo（5 MB 以下）
        • 檔名用小寫品牌名，例如 canon.png、sony.png、nikon.png、fujifilm.png、omsystem.png
        • 模糊背景可另放淺色版：sony_dark.png

        放好後切換一下樣式或重新開啟，頁尾就會出現 logo；沒有檔案的品牌顯示成純文字。
        字體可放 .ttf / .otf / .ttc，之後在「進階 → 字體」選用。
        """
        alert.addButton(withTitle: "打開 logo 資料夾")
        alert.addButton(withTitle: "打開字體資料夾")
        alert.addButton(withTitle: "關閉")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openFolder(logos)
        case .alertSecondButtonReturn: openFolder(fonts)
        default: break
        }
    }

    /// Creates the folder when missing and shows it in Finder; never opens something that is not a folder.
    private static func openFolder(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
