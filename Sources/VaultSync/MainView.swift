import SwiftUI
import AppKit
import ServiceManagement
import VaultSyncCore

enum Destination: String, CaseIterable {
    case vaults = "文库", devices = "设备", conflicts = "待合并", history = "版本历史", settings = "设置"
    var icon: String {
        switch self { case .vaults: return "square.stack.3d.up"; case .devices: return "desktopcomputer"; case .conflicts: return "arrow.triangle.branch"; case .history: return "clock.arrow.circlepath"; case .settings: return "gearshape" }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var destination: Destination = .vaults
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.white).frame(width: 40, height: 40).background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 12))
                    Text("VaultSync").font(.headline)
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Destination.allCases, id: \.self, selection: $destination) { item in
                    HStack { Label(item.rawValue, systemImage: item.icon); Spacer(); if item == .conflicts && !model.conflicts.isEmpty { Text("\(model.conflicts.count)").font(.caption).padding(.horizontal, 7).background(.orange.opacity(0.15), in: Capsule()) }; if item == .devices && !model.incoming.isEmpty { Text("\(model.incoming.count)").font(.caption).foregroundStyle(.orange) } }.tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Label(model.config.deviceName, systemImage: "laptopcomputer")
                    if model.paused { Text("已暂停").foregroundStyle(.secondary) }
                }.font(.caption).padding(16)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(destination.rawValue).font(.system(size: 27, weight: .semibold))
                    Spacer()
                    if model.scanning { ProgressView().controlSize(.small) }
                    Button { model.scan() } label: { Label("扫描", systemImage: "arrow.clockwise") }.disabled(model.scanning || model.paused)
                    Button { model.togglePaused() } label: { Image(systemName: model.paused ? "play" : "pause") }.help(model.paused ? "继续本地同步" : "暂停本地同步")
                }.padding(26)
                Divider()
                Group {
                    switch destination {
                    case .vaults: VaultsView()
                    case .devices: DevicesView()
                    case .conflicts: ConflictsView()
                    case .history: HistoryView()
                    case .settings: SettingsView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.engineID.isEmpty ? Color.secondary : Color.green).frame(width: 6, height: 6)
                    Text(model.transferSummary).lineLimit(1).help(model.transferSummary)
                    if let status = model.transferStatus, status.isReceiving { ProgressView(value: status.fractionReceived).frame(width: 90) }
                    Spacer()
                    if !model.conflicts.isEmpty { Text("\(model.conflicts.count) 项待合并") }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { if !model.incoming.isEmpty { destination = .devices } }
        .onChange(of: model.incoming.count) { count in if count > 0 { destination = .devices; NSApp.requestUserAttention(.informationalRequest) } }
    }
}

struct EmptyViewCard: View {
    var icon: String, title: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 42, weight: .light)).foregroundStyle(.indigo)
            Text(title).font(.title3.weight(.semibold))
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VaultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var removing: VaultMapping?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("\(model.config.vaults.count) 个文库", systemImage: "square.stack.3d.up").foregroundStyle(.secondary)
                Spacer(); Button { adding = true } label: { Label("添加文库", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.indigo)
            }
            if model.statuses.isEmpty {
                EmptyViewCard(icon: "folder.badge.plus", title: "尚未添加文库")
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.statuses) { status in
                            VStack(alignment: .leading, spacing: 13) {
                                HStack {
                                    Image(systemName: "folder.fill").font(.title2).foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 4) { Text(status.mapping.name).font(.headline); Text(status.mapping.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    Spacer()
                                    Label(status.error != nil ? "需检查" : status.updated == nil ? "待扫描" : status.report.conflicts.isEmpty ? "已扫描" : "\(status.report.conflicts.count) 项待合并", systemImage: status.error != nil ? "exclamationmark.circle" : status.updated == nil ? "clock" : status.report.conflicts.isEmpty ? "checkmark.circle" : "arrow.triangle.branch").font(.caption).foregroundStyle(status.error != nil || !status.report.conflicts.isEmpty ? Color.orange : status.updated == nil ? Color.secondary : Color.green)
                                }
                                HStack {
                                    Text("\(status.report.files) 个文件"); Text("·"); Text("\(status.report.revisions) 个版本")
                                    Spacer()
                                    if let date = status.updated { Text(date, style: .time) }
                                }.font(.caption).foregroundStyle(.secondary)
                                if let error = status.error { Text(error).font(.caption).foregroundStyle(.red) }
                                ForEach(Array(status.report.notices.prefix(4)), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                                Divider()
                                HStack {
                                    Button("打开文件夹") { model.openFolder(status.mapping.path) }
                                    Button("复制文库 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(status.id, forType: .string) }
                                    Spacer(); Button("移除映射", role: .destructive) { removing = status.mapping }
                                }.buttonStyle(.borderless).font(.caption)
                            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
        }.padding(24).sheet(isPresented: $adding) { AddVaultView() }
            .alert("移除本机映射？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("取消", role: .cancel) { removing = nil }
                Button("移除", role: .destructive) { if let removing { model.removeVault(removing.id) }; removing = nil }
            } message: { Text("保留原文件与版本历史；配对设备仍可接收已共享的版本。") }
    }
}

struct AddVaultView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var path = ""
    @State private var id = ""
    @State private var settings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加文库").font(.title2.weight(.semibold))
            HStack { TextField("文库文件夹", text: $path).disabled(true); Button("选择…") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.runModal() == .OK { path = panel.url?.path ?? "" } } }
            TextField("文库 ID（新文库留空）", text: $id)
            if !model.config.offeredVaults.isEmpty {
                Menu("选择已有文库") { ForEach(model.config.offeredVaults) { vault in Button(vault.name) { id = vault.id } } }
            }
            Toggle("同步 Obsidian 设置和插件", isOn: $settings).help("不包含工作区布局。")
            if settings { Text("插件设置可能包含本机路径或凭据。").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("添加") { let count = model.config.vaults.count; model.addVault(url: URL(fileURLWithPath: path), id: id, syncSettings: settings); if model.config.vaults.count > count { dismiss() } }.buttonStyle(.borderedProminent).disabled(path.isEmpty) }
        }.padding(28).frame(width: 540)
    }
}

struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var pairing = false
    @State private var copied = false
    @State private var removing: Peer?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Image(systemName: "laptopcomputer").font(.largeTitle).foregroundStyle(.indigo); VStack(alignment: .leading) { Text(model.config.deviceName).font(.headline); Text("Tailscale · \(model.engineHost.isEmpty ? "未连接" : model.engineHost)").font(.caption).foregroundStyle(.secondary) }; Spacer() }
                    if !model.engineID.isEmpty { DisclosureGroup("设备 ID") { Text(model.engineID).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.font(.caption) }
                    HStack {
                        Button { Task { await model.startTransport() } } label: { Label(model.transportBusy ? "正在连接…" : "启动同步", systemImage: "network") }.buttonStyle(.borderedProminent).disabled(model.transportBusy || !model.engineID.isEmpty)
                        Button(copied ? "已复制" : "复制配对信息") { model.copyPairing(); copied = !model.engineID.isEmpty }.disabled(model.engineID.isEmpty)
                        Spacer(); if !model.engineID.isEmpty { Button("停止同步") { model.stopTransport() } }
                    }
                    Toggle("将此 Mac 设为 Base", isOn: Binding(
                        get: { model.config.isBase == true },
                        set: { model.setBase($0) }
                    ))
                    Text("新设备查找时优先显示 Base。配对仍需双方确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                PairingDiscoveryView()
                HStack { Text("已配对设备").font(.headline); Spacer(); Button { pairing = true } label: { Label("手动配对", systemImage: "doc.on.clipboard") } }
                if model.config.peers.isEmpty { Text("暂无设备").foregroundStyle(.secondary) }
                ForEach(model.config.peers) { peer in
                    HStack(spacing: 14) {
                        Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 5) { Text(peer.name).font(.headline).help(peer.id); Text(peer.host).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Label(model.connected[peer.id] == true ? "已连接" : "未连接", systemImage: model.connected[peer.id] == true ? "circle.fill" : "circle").font(.caption).foregroundStyle(model.connected[peer.id] == true ? Color.green : Color.secondary)
                        Button("移除", role: .destructive) { removing = peer }.buttonStyle(.borderless)
                    }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(24)
        }.sheet(isPresented: $pairing) { PairDeviceView() }
            .alert("移除这台设备？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("取消", role: .cancel) { removing = nil }
                Button("移除", role: .destructive) { if let removing { model.removePeer(removing) }; removing = nil }
            } message: { Text("停止与这台设备交换版本。它已经收到的内容仍保留在对方磁盘上。") }
    }
}

struct PairDeviceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var failure: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("手动配对").font(.title2.weight(.semibold))
            Text("配对后共享所有文库历史。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(height: 200).border(.secondary.opacity(0.2))
            if let failure { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("从剪贴板粘贴") { text = NSPasteboard.general.string(forType: .string) ?? ""; failure = nil }
                Spacer(); Button("取消") { dismiss() }.disabled(busy)
                Button(busy ? "正在添加…" : "添加设备") {
                    busy = true; failure = nil
                    Task { do { try await model.addPeer(text); dismiss() } catch { failure = error.localizedDescription }; busy = false }
                }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }.padding(28).frame(width: 560)
    }
}

struct PairingDiscoveryView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDirectDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("添加设备", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                Button(model.discovering ? "正在查找…" : "查找设备") {
                    showDirectDevices = false
                    Task { await model.discoverDevices() }
                }.buttonStyle(.borderedProminent).disabled(model.discovering || model.transportBusy)
            }
            if !model.pairingMessage.isEmpty { Text(model.pairingMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if !model.nearby.isEmpty && model.incoming.isEmpty && model.outboundName.isEmpty { Text("配对后共享所有文库历史。").font(.caption).foregroundStyle(.secondary) }
            if !model.outboundName.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("等待 \(model.outboundName) 确认").font(.headline)
                        Text(model.outboundCode).font(.system(size: 28, weight: .semibold, design: .monospaced)).tracking(5)
                        Text("请在对方核对数字后确认。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Button("取消请求") { model.cancelPairing() }.disabled(model.finishingPairing)
                }.padding(14).background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(model.incoming) { request in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(request.peer.name) 请求与你配对").font(.headline)
                    Text(request.peer.host).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(request.code).font(.system(size: 26, weight: .semibold, design: .monospaced)).tracking(5)
                        Spacer(); Button("拒绝") { model.rejectPairing(request) }.disabled(model.approvingID != nil)
                        Button(model.approvingID == request.id ? "确认中…" : "确认配对") { Task { await model.approvePairing(request) } }
                            .buttonStyle(.borderedProminent).disabled(model.approvingID != nil)
                    }
                    Text("核对六位数字。配对后共享所有文库历史。").font(.caption).foregroundStyle(.secondary)
                }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if model.config.isBase == true {
                ForEach(model.nearby, content: deviceRow)
            } else {
                let primary = model.nearby.filter { $0.isBase || isPaired($0) }
                let direct = model.nearby.filter { !$0.isBase && !isPaired($0) }
                ForEach(primary, content: deviceRow)
                if !direct.isEmpty {
                    if model.config.peers.isEmpty && primary.isEmpty {
                        Text("未发现在线的 Base。").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("其他设备（可选直连）", isExpanded: $showDirectDevices) {
                        VStack(spacing: 10) { ForEach(direct, content: deviceRow) }
                            .padding(.top, 8)
                    }
                }
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func isPaired(_ device: NearbyDevice) -> Bool {
        model.config.peers.contains { $0.id == device.id }
    }

    private func deviceRow(_ device: NearbyDevice) -> some View {
        HStack {
            Image(systemName: "laptopcomputer").foregroundStyle(.indigo)
            VStack(alignment: .leading) {
                HStack {
                    Text(device.peer.name)
                    if device.isBase { Text("Base").font(.caption).foregroundStyle(.indigo) }
                }
                Text(device.peer.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.connected[device.id] == true {
                Text("已连接").foregroundStyle(.green)
            } else {
                Button(isPaired(device) ? "重新请求配对" : "请求配对") {
                    Task { await model.requestPairing(device) }
                }.disabled(!model.outboundName.isEmpty)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section("本机") {
                TextField("设备名称", text: $model.config.deviceName).onSubmit { model.save() }
                Toggle("登录时启动 VaultSync", isOn: $login).onChange(of: login) { model.loginItem($0) }
            }
            Section("版本存储") {
                Text(model.base.path).font(.caption).textSelection(.enabled)
                Button("打开应用数据目录") { model.openFolder(model.base.path) }
                Text("历史版本不会自动清理。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
            }
        }.formStyle(.grouped).padding(12)
    }
}
