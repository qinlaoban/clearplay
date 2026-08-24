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
    /// 全局搜索词（非空时内容区显示搜索结果）
    @State private var searchText = ""

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
        // 全局可关闭错误提示
        .overlay(alignment: .bottom) {
            if let error = media.lastError {
                ErrorBanner(message: error) { media.lastError = nil }
                    .padding(.bottom, 20)
                    .zIndex(20)
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
                if !searchText.isEmpty {
                    GlobalSearchResults(query: searchText)
                } else {
                    switch section {
                    case .home, nil: HomeView()
                    case .movies: MediaGridView(kind: .movie, title: "电影")
                    case .shows: MediaGridView(kind: .episode, title: "剧集")
                    case .favorites: MediaGridView(favoritesOnly: true)
                    case .settings: SettingsView()
                    }
                }
            }
            // 海报/详情页导航目标（必须在 NavigationStack 内）
            .navigationDestination(for: MediaItem.self) { item in
                MediaDetailView(item: item)
            }
        }
        // 全局搜索 + 添加入口（工具栏）
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索影片")
        .toolbar {
            ToolbarItemGroup {
                if media.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在扫描资料库")
                }
                Menu {
                    Button("添加文件夹…") { showFolderImporter = true }
                    Button("导入视频文件…") { showFileImporter = true }
                    Divider()
                    Button("WebDAV 服务器…") { section = .settings }
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
        }
        .id(section) // 切换分区时重置导航栈
    }
}

/// 全局搜索结果（标题/剧名匹配，海报网格展示）
struct GlobalSearchResults: View {
    @Environment(LibraryViewModel.self) private var library
    @Query(sort: \MediaItem.addedAt, order: .reverse) private var allItems: [MediaItem]

    let query: String

    private var results: [MediaItem] {
        allItems.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.seriesName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .background(.cpBackground)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        ForEach(results) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
                .background(.cpBackground)
            }
        }
        .navigationTitle("搜索「\(query)」")
    }
}

/// 可关闭的错误提示条
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.cpBodyMed)
                .foregroundStyle(.white)
                .lineLimit(2)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.cpCaption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: CPMetrics.radius).fill(.cpElevated))
        .overlay(
            RoundedRectangle(cornerRadius: CPMetrics.radius).stroke(.cpDivider)
        )
        .shadow(color: .black.opacity(0.4), radius: 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                withAnimation { onDismiss() }
            }
        }
    }
}
