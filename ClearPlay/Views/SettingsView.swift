import SwiftUI
import SwiftData

/// 设置页：TMDB API Key、资料库目录管理、重新扫描
struct SettingsView: View {
    @AppStorage("tmdbApiKey") private var tmdbApiKey = ""

    @Environment(MediaLibraryViewModel.self) private var media
    @Query(sort: \LibraryFolder.addedAt) private var folders: [LibraryFolder]

    @State private var showFolderImporter = false

    var body: some View {
        Form {
            Section("TMDB 刮削") {
                TextField("API Key（themoviedb.org 申请）", text: $tmdbApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("填写后新扫描的影片会自动匹配海报与简介。可在 https://www.themoviedb.org/settings/api 免费申请。")
                    .font(.system(size: 11))
                    .foregroundStyle(.cpTextSubtle)
            }

            Section("资料库文件夹") {
                ForEach(folders) { folder in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.cpPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(folder.path)
                                .font(.system(size: 11))
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
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                media.addFolder(url: url)
            }
        }
    }
}
