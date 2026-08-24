import Foundation
import AVFoundation
import Observation

/// 媒体库视图模型：管理导入列表、元数据缓存、持久化与播放位置记忆
@Observable
final class LibraryViewModel {
    private(set) var items: [VideoItem] = []
    /// 当前正在播放的条目（nil 表示无播放）
    var current: VideoItem?

    /// 缩略图缓存 [条目ID: CGImage]
    private(set) var thumbnails: [UUID: CGImage] = [:]
    /// 时长缓存 [条目ID: 秒]
    private(set) var durations: [UUID: Double] = [:]
    /// 播放位置记忆 [视频URL字符串: 秒]
    private(set) var resumePositions: [String: Double] = [:]
    /// 位置落盘回调：由媒体库桥接写入 SwiftData（海报墙进度条用）
    var onPositionSave: ((URL, Double) -> Void)?

    /// 从海报墙发起播放：构建播放队列并定位到起始条目
    func play(queue: [MediaItem], start: MediaItem) {
        items = queue.map { VideoItem(id: UUID(), url: $0.url) }
        // 续播位置以 SwiftData 记录为准，注入位置表供 PlayerView 读取
        for m in queue where m.resumeSeconds > 3 {
            resumePositions[m.url.absoluteString] = m.resumeSeconds
        }
        current = items.first { $0.url == start.url }
    }

    // MARK: - 持久化

    private struct PersistedItem: Codable { var bookmark: Data }

    private struct LibraryStore: Codable {
        var items: [PersistedItem] = []
        var positions: [String: Double] = [:]
    }

    private var storeFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ClearPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    /// 启动时从磁盘恢复媒体库（安全作用域书签）
    func restoreFromDisk() {
        guard items.isEmpty,
              let data = try? Data(contentsOf: storeFile),
              let store = try? JSONDecoder().decode(LibraryStore.self, from: data)
        else { return }

        resumePositions = store.positions
        for entry in store.items {
            guard let url = resolve(entry.bookmark) else { continue }
            append(url: url)
        }
    }

    func persist() {
        let entries = items.compactMap { item -> PersistedItem? in
            #if os(macOS)
            let opts: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkCreationOptions = []
            #endif
            guard let data = try? item.url.bookmarkData(options: opts) else { return nil }
            return PersistedItem(bookmark: data)
        }
        let store = LibraryStore(items: entries, positions: resumePositions)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeFile, options: .atomic)
        }
    }

    /// 从书签数据还原 URL 并保持沙盒访问权
    private func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: opts,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: - 列表管理

    /// 导入视频文件，去重并获取沙盒安全访问权限
    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            // 保持安全作用域访问开启，整个会话期间可读
            _ = url.startAccessingSecurityScopedResource()
            append(url: url)
        }
        if current == nil, let first = items.first {
            current = first
        }
        persist()
    }

    private func append(url: URL) {
        let item = VideoItem(id: UUID(), url: url)
        items.append(item)
        loadMetadata(for: item)
    }

    func remove(_ item: VideoItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        durations[item.id] = nil
        resumePositions.removeValue(forKey: item.url.absoluteString)
        if current?.id == item.id {
            current = items.first
        }
        persist()
    }

    func index(of item: VideoItem) -> Int {
        items.firstIndex { $0.id == item.id } ?? -1
    }

    /// 播放列表上/下一曲，越界返回 nil
    func step(from item: VideoItem, offset: Int) -> VideoItem? {
        guard let i = items.firstIndex(where: { $0.id == item.id }), i != -1 else { return nil }
        let next = i + offset
        return items.indices.contains(next) ? items[next] : nil
    }

    // MARK: - 播放位置记忆

    func savePosition(for item: VideoItem, seconds: Double) {
        resumePositions[item.url.absoluteString] = seconds
        onPositionSave?(item.url, seconds)
        persist()
    }

    /// 查询续播位置；不足 3 秒视为从头看
    func resumePosition(for item: VideoItem) -> Double? {
        guard let p = resumePositions[item.url.absoluteString], p > 3 else { return nil }
        return p
    }

    // MARK: - 元数据加载

    /// 异步生成时长 + 缩略图
    private func loadMetadata(for item: VideoItem) {
        Task { [weak self] in
            let asset = AVURLAsset(url: item.url)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                self?.durations[item.id] = duration.seconds
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            // 取第 1 秒处的画面作为封面；失败再试第 0 秒
            for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
                if let image = try? await generator.image(at: time).image {
                    self?.thumbnails[item.id] = image
                    break
                }
            }
        }
    }
}
