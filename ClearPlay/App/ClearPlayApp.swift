import SwiftUI
import SwiftData

@main
struct ClearPlayApp: App {
    /// SwiftData 容器：媒体条目 + 资料库目录
    private let container: ModelContainer
    @State private var library = LibraryViewModel()
    @State private var mediaLib: MediaLibraryViewModel
    @State private var cloud = CloudSyncService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        debugLog("app launched")
        container = AppDatabase.shared
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
                        let queue = MediaQueue.build(start: item, context: container.mainContext)
                        library.play(queue: queue.isEmpty ? [item] : queue, start: item)
                    }

                    // 位置落盘桥：同步写回 SwiftData + 推送到 iCloud
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
                            cloud.push(path: key, seconds: seconds, duration: item.durationSeconds)
                        }
                    }

                    // 启动：恢复旧播放队列 → 刷新 WebDAV 鉴权表 → 扫描资料库 → 刮削
                    library.restoreFromDisk()
                    mediaLib.refreshAuthStore()

                    // iCloud 续播同步：先拉取其他设备的进度，再启动本地扫描
                    await cloud.activate()
                    await cloud.pull { updates in
                        CloudSyncService.apply(updates, to: container.mainContext)
                    }

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
                    // iOS 退后台时落盘播放位置；回前台时拉取其他设备进度
                    if phase == .background {
                        library.persist()
                        cloud.flush()
                    } else if phase == .active {
                        Task {
                            await cloud.pull { updates in
                                CloudSyncService.apply(updates, to: container.mainContext)
                            }
                        }
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}
