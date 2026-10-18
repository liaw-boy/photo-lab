import SwiftUI

/// The list of sources: folders (with how many photos each holds) and the imported photos.
struct SourceManagerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Paper.gap) {
            Text("來源管理").font(.system(size: 18, weight: .bold))
            Text("這裡只是從清單移除，不會刪除任何照片。「已輸出」以目前的輸出資料夾計算。").font(.system(size: 12))
                .foregroundStyle(Paper.muted)
            ScrollView {
                VStack(spacing: Paper.inner) {
                    row(title: "全部照片", subtitle: "所有資料夾與已匯入的照片", count: nil,
                        active: model.view == .all, select: { model.view = .all }, remove: nil)
                    ForEach(model.folders, id: \.self) { f in
                        row(title: f.lastPathComponent, subtitle: f.path, count: model.folderCounts[f],
                            exported: model.exportedCounts[f],
                            active: model.view == .folder(f),
                            missing: !FileManager.default.fileExists(atPath: f.path),
                            select: { model.view = .folder(f) }, remove: { model.removeFolder(f) })
                    }
                    if !model.imported.isEmpty {
                        row(title: "已匯入", subtitle: "單獨匯入的照片", count: model.importedCount ?? model.imported.count,
                            exported: model.importedExported,
                            active: model.view == .imported, select: { model.view = .imported },
                            remove: { model.clearImported() })
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("＋ 資料夾") { model.chooseFolder() }.buttonStyle(PaperButtonStyle(compact: true))
                Button("＋ 照片") { model.choosePhotos() }.buttonStyle(PaperButtonStyle(compact: true))
                Button("清除失效項目") { model.clearMissing() }.buttonStyle(PaperButtonStyle(compact: true))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(PaperButtonStyle(filled: true, compact: true))
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(Paper.bg)
        .preferredColorScheme(.light)
        .onAppear { model.countsShowExported = true; model.refreshCounts() }
        .onDisappear { model.countsShowExported = false }
    }

    private func row(title: String, subtitle: String, count: Int?, exported: Int? = nil, active: Bool,
                     missing: Bool = false,
                     select: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(missing ? "找不到這個資料夾" : subtitle).font(.system(size: 11))
                    .foregroundStyle(missing ? Color.red : Paper.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let count {
                Text(exported.map { "\(count) 張 · 已輸出 \($0)" } ?? "\(count) 張")
                    .font(.system(size: 12)).foregroundStyle(Paper.muted)
                    .help("已輸出：目前的輸出資料夾裡已有它的輸出檔")
            }
            if let remove {
                Button("移除", action: remove).buttonStyle(PaperButtonStyle(compact: true))
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Paper.ink, lineWidth: active ? Paper.line : Paper.thin))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}
