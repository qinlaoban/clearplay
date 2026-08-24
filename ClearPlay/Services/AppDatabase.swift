import Foundation
import SwiftData

/// 全局共享 SwiftData 容器（App 与 App Intents 查询共用同一份存储）
enum AppDatabase {
    static let shared: ModelContainer = {
        let schema = Schema([MediaItem.self, LibraryFolder.self, WebDAVServer.self])
        let config = ModelConfiguration("ClearPlay", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            debugLog("ModelContainer init failed: \(error), fallback in-memory")
            // 兜底：内存模式保证 App 可用
            return try! ModelContainer(
                for: MediaItem.self, LibraryFolder.self, WebDAVServer.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }()
}

/// 播放队列构建规则（电影=全部电影按标题；剧集=同剧分集按季集号）
@MainActor
enum MediaQueue {
    static func build(start item: MediaItem, context: ModelContext) -> [MediaItem] {
        let all = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        if item.kind == .episode, let series = item.seriesName {
            return all
                .filter { $0.kind == .episode && $0.seriesName == series }
                .sorted { ($0.season ?? 0, $0.episodeNumber ?? 0) < ($1.season ?? 0, $1.episodeNumber ?? 0) }
        }
        return all.filter { $0.kind == .movie }.sorted { $0.displayTitle < $1.displayTitle }
    }

    /// 按 path（本地路径或远程 URL）查找条目
    static func find(path: String, context: ModelContext) -> MediaItem? {
        var desc = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.path == path })
        desc.fetchLimit = 1
        return try? context.fetch(desc).first
    }
}

/// 跨入口播放请求总线：
/// App Intents / Spotlight 点击 → 写入待播 path 并发通知 → ContentView 统一消费并开始播放
@MainActor
enum PendingPlay {
    static var path: String?

    static func request(_ path: String) {
        Self.path = path
        NotificationCenter.default.post(name: .clearplayPlayRequested, object: nil)
    }
}

extension Notification.Name {
    static let clearplayPlayRequested = Notification.Name("clearplay.playRequested")
}
