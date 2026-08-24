import SwiftUI
import SwiftData

/// 设置页：TMDB API Key、资料库目录管理、重新扫描
struct SettingsView: View {
    @AppStorage("tmdbApiKey") private var tmdbApiKey = ""
    @State private var osApiKey = UserDefaults.standard.string(forKey: "opensubtitlesApiKey") ?? ""
    @State private var osUsername = OpenSubtitlesAccount.username
    @State private var osPassword = ""

    @Environment(MediaLibraryViewModel.self) private var media
    @Query(sort: \LibraryFolder.addedAt) private var folders: [LibraryFolder]
    @Query(sort: \WebDAVServer.addedAt) private var servers: [WebDAVServer]

    @State private var showFolderImporter = false
    @State private var showServerForm = false
    /// 正在浏览的服务器（非 nil 时显示浏览器）
    @State private var browsingServer: WebDAVServer?

    var body: some View {
        Form {
            Section("TMDB 刮削") {
                TextField("API Key（themoviedb.org 申请）", text: $tmdbApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("填写后新扫描的影片会自动匹配海报与简介。可在 https://www.themoviedb.org/settings/api 免费申请。")
                    .font(.cpCaption)
                    .foregroundStyle(.cpTextSubtle)
            }

            Section("WebDAV 导入") {
                ForEach(servers) { server in
                    HStack {
                        Image(systemName: "cloud.fill")
                            .foregroundStyle(.cpPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .font(.cpBodyMed)
                            Text(server.baseURL)
                                .font(.cpCaption)
                                .foregroundStyle(.cpTextSubtle)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("浏览导入") {
                            browsingServer = server
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            media.removeServer(server)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    showServerForm = true
                } label: {
                    Label("添加服务器…", systemImage: "plus")
                }
                if media.isScanning {
                    Label("正在扫描远程目录…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.cpSmall)
                        .foregroundStyle(.cpTextSubtle)
                }
            }

            Section("本地文件夹") {
                ForEach(folders) { folder in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.cpPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                                .font(.cpBodyMed)
                            Text(folder.path)
                                .font(.cpCaption)
                                .foregroundStyle(.cpTextSubtle)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            media.removeFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { media.removeFolder(folders[i]) }
                }

                Button {
                    showFolderImporter = true
                } label: {
                    Label("添加文件夹…", systemImage: "plus")
                }
            }

            Section("在线字幕（OpenSubtitles）") {
                TextField("API Key（opensubtitles.com 申请）", text: $osApiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("用户名（可选，下载字幕需要）", text: $osUsername)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $osPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveAccount)
                Text("在 https://www.opensubtitles.com 免费申请 API Key。填写用户名密码后才能下载字幕文件；仅搜索无需登录。")
                    .font(.cpCaption)
                    .foregroundStyle(.cpTextSubtle)
            }

            Section("维护") {
                Button {
                    Task { await media.scanAndScrape() }
                } label: {
                    Label(media.isScanning ? "扫描中…" : "立即重新扫描",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(media.isScanning)

                Button {
                    Task { await media.scrapePending() }
                } label: {
                    Label(media.isScraping ? "刮削中…" : "刮削未处理的影片",
                          systemImage: "sparkles")
                }
                .disabled(media.isScraping || tmdbApiKey.isEmpty)
            }

            if let error = media.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .background(.cpBackground)
        .navigationTitle("设置")
        .onDisappear { saveAccount() }
        .onChange(of: osApiKey) { _, _ in saveAccount() }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                media.addFolder(url: url)
            }
        }
        .sheet(isPresented: $showServerForm) {
            WebDAVServerFormSheet()
                .environment(media)
        }
        .sheet(item: $browsingServer) { server in
            NavigationStack {
                WebDAVBrowserView(server: server) { path in
                    Task { await media.importWebDAVFolder(server: server, path: path) }
                }
            }
        }
    }

    /// OpenSubtitles 配置持久化：Key 存 UserDefaults，账号存 Keychain
    private func saveAccount() {
        UserDefaults.standard.set(osApiKey, forKey: "opensubtitlesApiKey")
        OpenSubtitlesAccount.setUsername(osUsername)
        if !osPassword.isEmpty {
            OpenSubtitlesAccount.setPassword(osPassword)
        }
    }
}
