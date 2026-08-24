import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreSpotlight

/// 侧栏导航分区
enum SidebarSection: String, CaseIterable, Hashable {
    case home = "首页"
    case movies = "电影"
    case shows = "剧集"
    case favorites = "收藏"
    case settings = "设置"

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film.fill"
        case .shows: "tv.fill"
        case .favorites: "heart.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// 主界面：NavigationSplitView 侧栏 + 内容分区 + 全屏播放器
struct ContentView: View {
    @Environment(LibraryViewModel.self) private var library
    @Environment(MediaLibraryViewModel.self) private var media

    @State private var section: SidebarSection? = .home
    @State private var showFolderImporter = false
    @State private var showFileImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .cpTheme()
        .background(.cpBackground)
        // App Intents / Spotlight 触发的播放请求
        .onReceive(NotificationCenter.default.publisher(for: .clearplayPlayRequested)) { _ in
            consumePendingPlay()
        }
        .task { consumePendingPlay() } // 兜底：冷启动时 intent 已先于 UI 写入
        // Spotlight 点击结果回跳
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                play(path: path)
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                media.addFolder(url: url)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                media.addFiles(urls: urls)
            }
        }
        // 播放器覆盖层：current 非空时铺满窗口
        .overlay {
            if let item = library.current {
                PlayerView(item: item, library: library)
                    .id(item.id)
                    .background(.black)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }

    // MARK: - 外部播放请求

    @Environment(\.modelContext) private var modelContext

    /// 消费 PendingPlay 中待播条目
    private func consumePendingPlay() {
        guard let path = PendingPlay.path else { return }
        PendingPlay.path = nil
        play(path: path)
    }

    private func play(path: String) {
        guard let item = MediaQueue.find(path: path, context: modelContext) else {
            media.lastError = "找不到影片，可能已被移出资料库"
            return
        }
        library.play(queue: MediaQueue.build(start: item, context: modelContext), start: item)
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(SidebarSection.allCases, id: \.self) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .tag(s)
            }

            Section("导入") {
                if media.isScanning {
                    Label("扫描中…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.cpTextSubtle)
                }
                Button {
                    showFolderImporter = true
                } label: {
                    Label("添加文件夹…", systemImage: "folder.badge.plus")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("导入视频文件…", systemImage: "plus")
                }
                Button {
                    section = .settings
                } label: {
                    Label("WebDAV 服务器…", systemImage: "externaldrive.badge.plus")
                }
            }
        }
        .navigationTitle("ClearPlay")
        #if os(macOS)
        .frame(minWidth: 220)
        #endif
    }

    // MARK: - 内容区

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            Group {
                switch section {
                case .home, nil: HomeView()
                case .movies: MediaGridView(kind: .movie, title: "电影")
                case .shows: MediaGridView(kind: .episode, title: "剧集")
                case .favorites: MediaGridView(favoritesOnly: true)
                case .settings: SettingsView()
                }
            }
            // 海报/详情页导航目标（必须在 NavigationStack 内）
            .navigationDestination(for: MediaItem.self) { item in
                MediaDetailView(item: item)
            }
        }
        .id(section) // 切换分区时重置导航栈
    }
}
