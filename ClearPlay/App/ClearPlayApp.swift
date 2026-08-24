import SwiftUI
import SwiftData

@main
struct ClearPlayApp: App {
    /// SwiftData 容器：媒体条目 + 资料库目录
    private let container: ModelContainer
    @State private var library = LibraryViewModel()
    @State private var mediaLib: MediaLibraryViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        debugLog("app launched")
        let schema = Schema([MediaItem.self, LibraryFolder.self, WebDAVServer.self])
        let config = ModelConfiguration("ClearPlay", schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            debugLog("ModelContainer init failed: \(error), fallback in-memory")
            // 兜底：内存模式保证 App 可用
            container = try! ModelContainer(
                for: MediaItem.self, LibraryFolder.self, WebDAVServer.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        _mediaLib = State(initialValue: MediaLibraryViewModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .environment(library)
                .environment(mediaLib)
                .preferredColorScheme(.dark)
                .task {
                    // 导入散装文件后自动开始播放（队列按类型分组）
                    mediaLib.onFilesImported = { item in
                        let ctx = container.mainContext
                        let all = (try? ctx.fetch(FetchDescriptor<MediaItem>())) ?? []
                        let queue: [MediaItem]
                        if item.kind == .episode, let series = item.seriesName {
                            queue = all
                                .filter { $0.kind == .episode && $0.seriesName == series }
                                .sorted { ($0.season ?? 0, $0.episodeNumber ?? 0) < ($1.season ?? 0, $1.episodeNumber ?? 0) }
                        } else {
                            queue = all.filter { $0.kind == .movie }.sorted { $0.displayTitle < $1.displayTitle }
                        }
                        library.play(queue: queue.isEmpty ? [item] : queue, start: item)
                    }

                    // 位置落盘桥：同步写回 SwiftData（海报墙进度条/续播）
                    library.onPositionSave = { url, seconds in
                        let ctx = container.mainContext
                        // 本地条目 path 是文件路径，远程条目 path 是完整 URL 字符串
                        let key = url.isFileURL ? url.path : url.absoluteString
                        var desc = FetchDescriptor<MediaItem>(
                            predicate: #Predicate { $0.path == key }
                        )
                        desc.fetchLimit = 1
                        if let item = try? ctx.fetch(desc).first {
                            item.resumeSeconds = seconds
                            item.playedAt = Date()
                            try? ctx.save()
                        }
                    }

                    // 启动：恢复旧播放队列 → 刷新 WebDAV 鉴权表 → 扫描资料库 → 刮削
                    library.restoreFromDisk()
                    mediaLib.refreshAuthStore()
                    await mediaLib.scanAndScrape()

                    // 调试辅助：CLEARPLAY_TEST_FILE=/path/to.mp4 自动加载
                    if let path = ProcessInfo.processInfo.environment["CLEARPLAY_TEST_FILE"] {
                        debugLog("autoload: \(path)")
                        library.add(urls: [URL(fileURLWithPath: path)])
                    }
                    // 调试辅助：CLEARPLAY_TEST_FOLDER=/path/to/dir 自动添加资料库目录
                    if let path = ProcessInfo.processInfo.environment["CLEARPLAY_TEST_FOLDER"] {
                        debugLog("test folder: \(path)")
                        mediaLib.addFolder(url: URL(fileURLWithPath: path))
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // iOS 退后台时落盘播放位置
                    if phase == .background {
                        library.persist()
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}
