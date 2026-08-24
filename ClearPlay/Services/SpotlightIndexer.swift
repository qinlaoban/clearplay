import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Spotlight 索引管理：全量重建媒体条目索引，点击结果回跳 App 播放
enum SpotlightIndexer {
    private static let domain = "media"
    private static let index = CSSearchableIndex(name: "com.clearplay.app.index")

    /// 全量重建（先清空本域再写入，保证删除的条目从 Spotlight 消失）
    static func reindexAll(_ items: [MediaItem]) {
        let searchable = items.map { item -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .movie)
            attrs.title = item.displayTitle
            attrs.contentDescription = item.overview ?? subtitle(for: item)
            if let r = item.rating { attrs.rating = NSNumber(value: r) }
            if let series = item.seriesName { attrs.keywords = [series] }
            // 海报缩略图（海报缓存都在本地，远程条目同样适用）
            let posterURL = PosterStore.cachesDirectory.appendingPathComponent(item.posterFile ?? "")
            if let data = try? Data(contentsOf: posterURL) {
                attrs.thumbnailData = data
            }
            return CSSearchableItem(
                uniqueIdentifier: item.path,
                domainIdentifier: domain,
                attributeSet: attrs
            )
        }

        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { deleteError in
            guard searchable.isEmpty else {
                index.indexSearchableItems(searchable) { _ in }
                return
            }
            if let deleteError { debugLog("spotlight clear failed: \(deleteError)") }
        }
    }

    private static func subtitle(for item: MediaItem) -> String {
        guard item.kind == .episode, let s = item.season, let e = item.episodeNumber else {
            return item.year.map(String.init) ?? ""
        }
        return "第 \(s) 季 第 \(e) 集"
    }
}
