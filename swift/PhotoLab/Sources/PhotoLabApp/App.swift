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
        }

        Window("樣式編輯器", id: "style-editor") {
            StyleEditorView(model: model)
                .preferredColorScheme(scheme)
        }
        .defaultSize(width: 1180, height: 700)
    }
}
