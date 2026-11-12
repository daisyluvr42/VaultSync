import SwiftUI
import AppKit
import VaultSyncCore

struct ConflictsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: ConflictItem?
    var body: some View {
        Group {
            if model.conflicts.isEmpty {
                EmptyViewCard(icon: "checkmark.seal", title: "暂无冲突")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.conflicts) { item in
                            HStack(spacing: 16) {
                                Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.conflict.path).font(.headline)
                                    Text("\(item.vaultName) · \(item.conflict.heads.count) 个分支 · \(item.conflict.base == nil ? "手动比较" : "可进行三方合并")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Button("比较与合并") { selected = item }.buttonStyle(.borderedProminent).tint(.indigo)
                            }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }.padding(24)
                }
            }
        }.sheet(item: $selected) { item in MergeEditor(item: item).environmentObject(model) }
    }
}

struct SavedDraft: Codable { var heads: [String]; var text: String }
struct MergeEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let item: ConflictItem
    @State private var versions: [RevisionContent] = []
    @State private var ancestor: RevisionContent?
    @State private var selectedID = ""
    @State private var compareID = ""
    @State private var draft = ""
    @State private var diff = ""
    @State private var message = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var confirm = false
    @State private var pendingData: Data?
    @State private var pendingDescription = ""
    var selected: RevisionContent? { versions.first { $0.id == selectedID } }
    var allText: Bool { !versions.isEmpty && versions.allSatisfy { $0.data == nil || $0.text != nil } }
    var hasMergeMarkers: Bool { draft.split(separator: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix("||||||| ") || $0.hasPrefix(">>>>>>> ") } }
    var draftURL: URL { model.base.appendingPathComponent("Drafts").appendingPathComponent(Codec.hash(Data(item.id.utf8)) + ".json") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("比较与合并").font(.title2.weight(.semibold)); Text("\(item.vaultName) / \(item.conflict.path)").foregroundStyle(.secondary) }
                Spacer(); Button("稍后处理") { saveDraft(); dismiss() }
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if !loaded { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                HStack {
                    Picker("查看分支", selection: $selectedID) { ForEach(versions) { version in Text(label(version)).tag(version.id) } }.frame(maxWidth: 400)
                    Button("导出此版本…") { if let selected { export(selected) } }.disabled(selected?.data == nil)
                    Spacer()
                    Button("生成三方合并预览") { preview() }.disabled(ancestor?.data == nil || !allText || versions.contains { $0.data == nil } || busy)
                }
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("分支内容").font(.headline); Spacer(); if allText { Button("填入合并草稿") { draft = selected?.text ?? "" } } }
                        ScrollView { Text(selected?.data == nil ? "此分支删除了文件。" : selected?.text ?? "二进制附件 · \(selected?.data?.count ?? 0) 字节").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }.background(Color(nsColor: .textBackgroundColor))
                        HStack {
                            Picker("对比", selection: $compareID) { ForEach(versions) { Text(label($0)).tag($0.id) } }
                            Button("显示 diff") { showDiff() }.disabled(!allText || selectedID == compareID)
                        }
                    }.frame(minWidth: 350)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(allText ? "合并草稿" : "附件保留方式").font(.headline)
                        if allText { TextEditor(text: $draft).font(.system(.body, design: .monospaced)).border(.secondary.opacity(0.2)) }
                        else { EmptyViewCard(icon: "doc.on.doc", title: "选择附件版本") }
                    }.frame(minWidth: 350)
                }
                if !diff.isEmpty { ScrollView { Text(diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(height: 140).background(.secondary.opacity(0.05)) }
                HStack {
                    if ancestor == nil { Text("需手动合并").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("确认保留选中版本") { pendingData = selected?.data; pendingDescription = selected?.data == nil ? "确认删除当前文件。" : "将选中分支作为合并结果。"; confirm = true }.disabled(selected == nil || busy)
                    if allText { Button("确认应用草稿") { pendingData = Data(draft.utf8); pendingDescription = "将右侧草稿写回笔记。"; confirm = true }.buttonStyle(.borderedProminent).disabled(busy || hasMergeMarkers) }
                }
            }
        }.padding(24).frame(width: 1060, height: 740)
            .onAppear { model.loadContents(item) { contents, base in
                versions = contents; ancestor = base; selectedID = contents.first?.id ?? ""; compareID = contents.dropFirst().first?.id ?? selectedID
                draft = contents.first?.text ?? ""
                if let data = try? Data(contentsOf: draftURL), let saved = try? JSONDecoder().decode(SavedDraft.self, from: data) {
                    draft = saved.text; message = saved.heads.sorted() == item.conflict.heads.map(\.id).sorted() ? "已恢复上次的合并草稿。" : "已恢复旧草稿，但分支已经变化，请重新比较全部版本。"
                }
                loaded = true
            } }
            .onChange(of: draft) { _ in if loaded { saveDraft() } }
            .alert("确认合并这些分支？", isPresented: $confirm) {
                Button("取消", role: .cancel) {}
                Button("确认合并") {
                    busy = true; saveDraft()
                    model.resolve(item, data: pendingData) { success in
                        busy = false
                        if success { try? FileManager.default.removeItem(at: draftURL); dismiss() }
                        else { message = model.error ?? "版本已变化，请保留草稿并重新打开此文件。" }
                    }
                }
            } message: { Text(pendingDescription + "所有原始分支仍保留在版本历史中。") }
    }
    func label(_ content: RevisionContent) -> String {
        let date = Date(timeIntervalSince1970: content.revision.payload.timestamp).formatted(date: .omitted, time: .shortened)
        return content.revision.payload.device + " · " + date + (content.data == nil ? " · 已删除" : "")
    }
    func saveDraft() {
        guard loaded, allText else { return }
        do {
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Codec.encode(SavedDraft(heads: item.conflict.heads.map(\.id), text: draft)).write(to: draftURL, options: .atomic)
        } catch { message = "草稿保存失败：\(error.localizedDescription)" }
    }
    func preview() {
        guard let base = ancestor?.data else { return }; busy = true
        let variants = versions.compactMap(\.data)
        Task {
            do {
                let result = try await Task.detached { try TextMerge.preview(base: base, versions: variants) }.value
                draft = result.text; message = result.hasConflicts ? "存在重叠修改，请编辑草稿并移除冲突标记后确认。" : "已生成合并预览，请核对内容后确认。"
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func showDiff() {
        guard let a = selected?.data, let b = versions.first(where: { $0.id == compareID })?.data else { message = "删除分支请直接查看原内容与删除状态。"; return }
        do { diff = try TextMerge.diff(a,b); if diff.isEmpty { diff = "两个版本内容相同。" } } catch { message = error.localizedDescription }
    }
    func export(_ version: RevisionContent) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: item.conflict.path).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url, let data = version.data { do { try data.write(to: url, options: .atomic) } catch { message = error.localizedDescription } }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var vaultID = ""
    @State private var path = ""
    @State private var paths: [String] = []
    @State private var versions: [RevisionContent] = []
    @State private var selectedID: String?
    @State private var restore = false
    var selected: RevisionContent? { versions.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("文库", selection: $vaultID) { Text("选择文库").tag(""); ForEach(model.config.vaults) { Text($0.name).tag($0.id) } }.frame(width: 250)
                Picker("文件", selection: $path) { Text("选择文件（含已删除）").tag(""); ForEach(paths, id: \.self) { Text($0).tag($0) } }
                Button("刷新") { loadPaths() }
            }
            if versions.isEmpty { EmptyViewCard(icon: "clock.arrow.circlepath", title: "暂无版本") }
            else {
                HSplitView {
                    List(versions, selection: $selectedID) { version in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(version.revision.payload.device).font(.headline)
                            Text(Date(timeIntervalSince1970: version.revision.payload.timestamp), style: .date)
                            HStack { Text(Date(timeIntervalSince1970: version.revision.payload.timestamp), style: .time); if version.data == nil { Text("删除").foregroundStyle(.orange) } }.font(.caption)
                        }.padding(.vertical, 7).tag(version.id)
                    }.frame(minWidth: 240, maxWidth: 320)
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView { Text(selected?.data == nil ? "此版本删除了文件。" : selected?.text ?? "二进制附件 · \(selected?.data?.count ?? 0) 字节").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }.background(Color(nsColor: .textBackgroundColor))
                        HStack { Text(selected.map { "版本 " + $0.id.prefix(12) } ?? "").font(.caption).foregroundStyle(.secondary); Spacer(); Button("恢复此版本…") { restore = true }.disabled(selected == nil) }
                    }.frame(minWidth: 300)
                }
            }
        }.padding(24).onAppear { if vaultID.isEmpty { vaultID = model.config.vaults.first?.id ?? "" }; loadPaths() }
            .onChange(of: vaultID) { _ in path = ""; versions = []; loadPaths() }
            .onChange(of: path) { _ in loadVersions() }
            .alert("恢复此历史版本？", isPresented: $restore) {
                Button("取消", role: .cancel) {}
                Button("恢复") { if let selected { model.restore(vaultID: vaultID, revision: selected.revision); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loadVersions() } } }
            } message: { Text("生成新的当前版本，并同步到其他设备。已有分支冲突时，请先完成合并。") }
    }
    func loadPaths() {
        model.historyPaths(vaultID: vaultID) { paths = $0; if !paths.contains(path) { path = paths.first ?? "" }; loadVersions() }
    }
    func loadVersions() {
        guard !path.isEmpty, !vaultID.isEmpty else { versions = []; return }
        model.history(vaultID: vaultID, path: path) { versions = $0; selectedID = $0.first?.id }
    }
}
