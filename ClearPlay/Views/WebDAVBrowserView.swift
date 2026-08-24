import SwiftUI
import SwiftData

/// WebDAV 服务器浏览与导入：逐级进入目录，"导入此目录"递归扫描入库
struct WebDAVBrowserView: View {
    let server: WebDAVServer
    /// 点击"导入此目录"回调（带当前目录路径，根为 ""）
    var onImport: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [WebDAVEntry] = []
    /// 当前目录路径（解码后，根为 ""）
    @State private var currentPath = ""
    @State private var pathHistory: [String] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var importRequested = false

    private var currentURL: URL? {
        server.url
    }

    var body: some View {
        VStack(spacing: 0) {
            // 面包屑导航
            HStack(spacing: 8) {
                if !pathHistory.isEmpty {
                    Button {
                        goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }
                Text(currentPath.isEmpty ? "/" : "/" + currentPath)
                    .font(.cpBodyMed)
                    .foregroundStyle(.cpTextSubtle)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button {
                    importRequested = true
                } label: {
                    Label("导入此目录", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cpCTA)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            listContent
        }
        .background(.cpBackground)
        #if os(macOS)
        .frame(width: 640, height: 520)
        #endif
        .navigationTitle(server.name)
        .task { await reload() }
        .alert("导入失败", isPresented: .init(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(
            "递归扫描当前目录并导入全部视频？", isPresented: $importRequested, titleVisibility: .visible
        ) {
            Button("开始导入") {
                onImport(currentPath)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading && entries.isEmpty {
            Spacer()
            ProgressView("正在连接…")
            Spacer()
        } else if entries.isEmpty, let error {
            ContentUnavailableView("无法读取目录", systemImage: "wifi.exclamationmark", description: Text(error))
        } else {
            List(entries) { entry in
                entryRow(entry)
            }
            .listStyle(.plain)
            .overlay(alignment: .bottom) {
                if isLoading {
                    ProgressView().padding(8)
                }
            }
        }
    }

    private func entryRow(_ entry: WebDAVEntry) -> some View {
        Button {
            if entry.isDirectory {
                Task { await enter(entry) }
            } else {
                importRequested = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "film")
                    .foregroundStyle(entry.isDirectory ? Color.cpPrimary : Color.cpTextSubtle)
                    .frame(width: 24)
                Text(entry.name)
                    .font(.cpBodyMed)
                    .foregroundStyle(.cpText)
                    .lineLimit(1)
                Spacer()
                if let size = entry.sizeBytes, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.cpCaption)
                        .foregroundStyle(.cpTextSubtle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 导航

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try RemoteAuthStore.makeClient(server: server)
            entries = try await client.list(path: currentPath)
            self.error = nil
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
    }

    private func enter(_ entry: WebDAVEntry) async {
        pathHistory.append(currentPath)
        currentPath = entry.url.path
        await reload()
    }

    private func goBack() {
        guard let previous = pathHistory.popLast() else { return }
        currentPath = previous
        Task { await reload() }
    }
}

/// 添加/编辑 WebDAV 服务器表单
struct WebDAVServerFormSheet: View {
    var existing: WebDAVServer?
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(MediaLibraryViewModel.self) private var media

    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("服务器") {
                    TextField("名称（如家里的 NAS）", text: $name)
                    TextField("地址（https://nas.local:5006/dav）", text: $address)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section("账号（匿名访问可留空）") {
                    TextField("用户名", text: $username)
                    SecureField("密码", text: $password)
                }
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("测试连接", systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(testing || address.isEmpty)

                    if let testResult {
                        Label(testResult, systemImage: testResult.hasPrefix("连接成功") ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(testResult.hasPrefix("连接成功") ? Color.green : Color.red)
                            .font(.cpSmall)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button(existing == nil ? "添加并保存" : "保存") {
                    media.addServer(name: name, baseURL: normalizedAddress,
                                    username: username, password: password)
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.isEmpty)
            }
            .padding(16)
        }
        .background(.cpBackground)
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
        .onAppear(perform: fillExisting)
    }

    /// 规范化地址：补 scheme、去尾部斜杠
    private var normalizedAddress: String {
        var str = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.isEmpty, !str.contains("://") { str = "http://" + str }
        while str.hasSuffix("/") { str.removeLast() }
        return str
    }

    private func fillExisting() {
        guard let existing else { return }
        name = existing.name
        address = existing.baseURL
        username = existing.username
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        testResult = nil
        let client = WebDAVClient(baseURL: URL(string: normalizedAddress + "/") ?? URL(fileURLWithPath: "/"),
                                  username: username, password: password)
        do {
            let entries = try await client.list(path: "")
            testResult = "连接成功，发现 \(entries.count) 个项目"
        } catch {
            testResult = "失败：\(error.localizedDescription)"
        }
    }
}
