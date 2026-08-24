import Foundation
import SwiftData
import AVFoundation
import Observation

/// 媒体库视图模型：资料库目录管理、文件扫描入库、TMDB 刮削调度
@MainActor
@Observable
final class MediaLibraryViewModel {
    private(set) var isScanning = false
    private(set) var isScraping = false
    /// 最近一次错误提示（UI 展示后手动置空）
    var lastError: String?
    /// 散装文件导入完成回调（首个新增条目），用于自动开始播放
    var onFilesImported: ((MediaItem) -> Void)?

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - 单文件导入

    /// 直接导入散装视频文件（不属于任何资料库目录）
    func addFiles(urls: [URL]) {
        let context = container.mainContext
        var added: [MediaItem] = []
        for url in urls {
            let path = url.path
            var desc = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.path == path })
            desc.fetchLimit = 1
            if (try? context.fetch(desc).first) != nil { continue }

            guard FilenameParser.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            let parsed = FilenameParser.parse(url.lastPathComponent)
            let item = MediaItem(path: path, folderPath: "", parsed: parsed)
            context.insert(item)
            added.append(item)
        }
        try? context.save()
        if let first = added.first {
            Task { [weak self] in
                await self?.loadMissingDurations()
                await self?.scrapePending()
                self?.onFilesImported?(first)
            }
        } else {
            lastError = "没有可导入的视频文件（可能已导入过）"
        }
    }

    /// 为时长缺失的条目补充读取时长
    private func loadMissingDurations() async {
        let context = container.mainContext
        let desc = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.durationSeconds <= 0 })
        guard let items = try? context.fetch(desc) else { return }
        for item in items {
            item.durationSeconds = await loadDuration(url: item.url)
        }
        try? context.save()
    }

    // MARK: - 资料库目录

    /// 添加资料库目录并立即扫描
    func addFolder(url: URL) {
        let context = container.mainContext
        let path = url.path
        if existsFolder(path: path, context: context) { return }
        guard let bookmark = try? url.bookmarkData() else {
            lastError = "无法为目录创建书签"
            return
        }
        context.insert(LibraryFolder(path: path, name: url.lastPathComponent, bookmark: bookmark))
        try? context.save()
        Task { await scanAndScrape() }
    }

    func removeFolder(_ folder: LibraryFolder) {
        let context = container.mainContext
        let path = folder.path
        let desc = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.folderPath == path })
        if let items = try? context.fetch(desc) {
            for item in items {
                PosterStore.remove(item.posterFile)
                PosterStore.remove(item.backdropFile)
                context.delete(item)
            }
        }
        context.delete(folder)
        try? context.save()
    }

    private func existsFolder(path: String, context: ModelContext) -> Bool {
        var desc = FetchDescriptor<LibraryFolder>(predicate: #Predicate { $0.path == path })
        desc.fetchLimit = 1
        return ((try? context.fetch(desc))?.isEmpty == false)
    }

    // MARK: - 扫描

    /// 全量扫描所有目录（增量入库新文件、清理失效记录），随后触发刮削
    func scanAndScrape() async {
        await scanAll()
        await scrapePending()
    }

    private func scanAll() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let mainContext = container.mainContext
        guard let folders = try? mainContext.fetch(FetchDescriptor<LibraryFolder>()) else { return }
        // 后台上下文做批量写入，避免阻塞主线程
        let bgContext = ModelContext(container)

        do {
            for folder in folders {
                guard let dirURL = folder.resolve() else { continue }
                let files = try FolderScanner.scan(folder: dirURL)
                let scannedPaths = Set(files.map { $0.url.path })

                for file in files {
                    let path = file.url.path
                    var desc = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.path == path })
                    desc.fetchLimit = 1
                    if let _ = try? bgContext.fetch(desc).first { continue }

                    let parsed = FilenameParser.parse(file.url.lastPathComponent)
                    let item = MediaItem(path: path, folderPath: folder.path, parsed: parsed)
                    bgContext.insert(item)
                    item.durationSeconds = await loadDuration(url: file.url)
                }

                // 清理已删除文件的记录
                let folderPath = folder.path
                let desc = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.folderPath == folderPath })
                for stale in try bgContext.fetch(desc) where !scannedPaths.contains(stale.path) {
                    PosterStore.remove(stale.posterFile)
                    PosterStore.remove(stale.backdropFile)
                    bgContext.delete(stale)
                }
            }
            try bgContext.save()
        } catch {
            lastError = "扫描失败：\(error.localizedDescription)"
        }
    }

    private func loadDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else { return 0 }
        return duration.seconds
    }

    // MARK: - TMDB 刮削

    /// 刮削所有未处理条目（每批最多 limit 条）
    func scrapePending(limit: Int = 30) async {
        guard !isScraping else { return }
        guard let key = tmdbAPIKey(), !key.isEmpty else { return }
        isScraping = true
        defer { isScraping = false }

        let service = TMDBService(apiKey: key)
        let bgContext = ModelContext(container)

        do {
            var desc = FetchDescriptor<MediaItem>(
                predicate: #Predicate { $0.scrapedAt == nil },
                sortBy: [SortDescriptor(\.addedAt)]
            )
            desc.fetchLimit = limit
            let pending = try bgContext.fetch(desc)

            for item in pending {
                await scrape(item, service: service, context: bgContext)
                try? bgContext.save()
                try? await Task.sleep(for: .milliseconds(250)) // 对 TMDB 限速
            }
        } catch {
            lastError = "刮削失败：\(error.localizedDescription)"
        }
    }

    /// 强制重刮单个条目（详情页"重新匹配"入口）
    func rescrape(_ item: MediaItem) async {
        guard let key = tmdbAPIKey(), !key.isEmpty else {
            lastError = "请先在设置中填写 TMDB API Key"
            return
        }
        item.scrapedAt = nil
        item.tmdbID = nil
        let service = TMDBService(apiKey: key)
        await scrape(item, service: service, context: container.mainContext)
        try? container.mainContext.save()
    }

    /// 单条刮削：电影搜 movie；剧集搜 tv 后把剧级海报套用到全部分集
    private func scrape(_ item: MediaItem, service: TMDBService, context: ModelContext) async {
        item.scrapedAt = Date() // 无论成败都标记，避免反复重试坏条目
        switch item.kind {
        case .movie:
            guard let result = try? await service.searchMovie(title: item.title, year: item.year) else {
                debugLog("scrape no match: \(item.path)")
                return
            }
            item.tmdbID = result.tmdbID
            item.overview = result.overview
            item.rating = result.rating
            item.posterFile = await downloadArtwork(
                service, remote: result.posterPath,
                cacheName: PosterStore.fileName(tmdbID: result.tmdbID, kind: "poster"), width: 500
            )
            item.backdropFile = await downloadArtwork(
                service, remote: result.backdropPath,
                cacheName: PosterStore.fileName(tmdbID: result.tmdbID, kind: "backdrop"), width: 1280
            )

        case .episode:
            let name = item.seriesName ?? item.title
            guard let result = try? await service.searchTV(title: name, year: nil) else {
                debugLog("scrape no match: \(item.path)")
                return
            }
            item.tmdbID = result.tmdbID
            let posterName = PosterStore.fileName(tmdbID: result.tmdbID, kind: "poster")
            item.posterFile = await downloadArtwork(
                service, remote: result.posterPath, cacheName: posterName, width: 500
            ) ?? (PosterStore.exists(posterName) ? posterName : nil)

            // 同剧其他未刮削分集直接复用结果（图按 tmdbID 缓存天然去重）
            let series = item.seriesName ?? ""
            let desc = FetchDescriptor<MediaItem>(
                predicate: #Predicate {
                    $0.seriesName == series && $0.scrapedAt == nil && $0.kindRaw == "episode"
                }
            )
            if let siblings = try? context.fetch(desc) {
                for sibling in siblings where sibling.id != item.id {
                    sibling.scrapedAt = Date()
                    sibling.tmdbID = result.tmdbID
                    sibling.posterFile = item.posterFile
                }
            }
        }
    }

    /// 下载 TMDB 图片到缓存，失败返回 nil
    private func downloadArtwork(
        _ service: TMDBService, remote: String?, cacheName: String, width: Int
    ) async -> String? {
        guard let remote else { return nil }
        return try? await service.downloadImage(remotePath: remote, cacheName: cacheName, width: width)
    }

    private func tmdbAPIKey() -> String? {
        UserDefaults.standard.string(forKey: "tmdbApiKey")
    }
}
