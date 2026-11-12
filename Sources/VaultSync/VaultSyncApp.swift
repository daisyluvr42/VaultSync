import SwiftUI
import AppKit

@main struct VaultSyncApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("VaultSync", id: "main") {
            MainView().environmentObject(model).frame(minWidth: 1020, minHeight: 690)
                .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("知道了", role: .cancel) { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
        .defaultSize(width: 1140, height: 780)
        .commands { CommandGroup(replacing: .appTermination) { Button("退出 VaultSync") { model.quit() }.keyboardShortcut("q") } }
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: { Label("VaultSync", systemImage: model.conflicts.isEmpty ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath") }
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("VaultSync · \(model.config.vaults.count) 个文库")
        if !model.conflicts.isEmpty { Text("\(model.conflicts.count) 项待合并") }
        if !model.incoming.isEmpty { Text("\(model.incoming.count) 个待确认配对请求") }
        Divider()
        Button("打开 VaultSync") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("立即扫描") { model.scan() }
        Button(model.paused ? "继续本地同步" : "暂停本地同步") { model.togglePaused() }
        Divider()
        Button("退出") { model.quit() }
    }
}
