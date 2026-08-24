import Foundation
import SwiftData

/// 媒体类型：电影 / 剧集单集
enum MediaKind: String, Codable {
    case movie
    case episode
}

/// 媒体条目（SwiftData）：本地视频文件 + 刮削元数据
@Model
final class MediaItem {
    /// 文件绝对路径，唯一键（同一路径只保留一条记录）
    #Unique<MediaItem>([\.path])
    var path: String
    var kindRaw: String = MediaKind.movie.rawValue

    // 解析出的基础元数据
    var title: String = ""
    var year: Int?
    /// 剧集所属剧名（电影为 nil）
    var seriesName: String?
    var season: Int?
    var episodeNumber: Int?

    // TMDB 刮削结果
    var tmdbID: Int?
    var overview: String?
    var rating: Double?
    /// 海报/背景图缓存文件名（位于 Caches/ClearPlay/Artwork）
    var posterFile: String?
    var backdropFile: String?
    /// 上次尝试刮削的时间（nil 表示从未刮削或待重试）
    var scrapedAt: Date?
    /// 刮削失败次数（连续失败达上限后标记放弃）
    var scrapeAttempts: Int = 0

    // 播放状态
    var durationSeconds: Double = 0
    var resumeSeconds: Double = 0
    var playedAt: Date?
    var favorite: Bool = false

    var addedAt: Date = Date()
    /// 所属资料库目录路径（目录被移除时用于清理）
    var folderPath: String = ""

    init(path: String, folderPath: String, parsed: FilenameParser.Result) {
        self.path = path
        self.folderPath = folderPath
        self.title = parsed.title
        self.year = parsed.year
        self.kindRaw = parsed.kind.rawValue
        self.seriesName = parsed.seriesName
        self.season = parsed.season
        self.episodeNumber = parsed.episodeNumber
    }

    // MARK: - 计算属性

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .movie }
    /// 本地文件 → file URL；远程条目（WebDAV）path 存完整 http(s) URL 字符串
    var url: URL {
        if let remote = URL(string: path), remote.scheme == "http" || remote.scheme == "https" {
            return remote
        }
        return URL(fileURLWithPath: path)
    }
    var isRemote: Bool { url.scheme == "http" || url.scheme == "https" }
    /// 海报墙展示用标题
    var displayTitle: String {
        if kind == .episode, let s = season, let e = episodeNumber {
            return "\(seriesName ?? title) S\(String(format: "%02d", s))E\(String(format: "%02d", e))"
        }
        return title
    }

    /// 是否值得继续观看（有进度且未看完 95%）
    var inProgress: Bool {
        guard resumeSeconds > 3 else { return false }
        if durationSeconds > 0 { return resumeSeconds / durationSeconds < 0.95 }
        return true
    }

    func artworkURL(_ name: String?) -> URL? {
        guard let name else { return nil }
        return PosterStore.cachesDirectory.appendingPathComponent(name)
    }
}
