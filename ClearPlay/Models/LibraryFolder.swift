import Foundation
import SwiftData

/// 资料库目录（SwiftData）：security-scoped bookmark 持久化
@Model
final class LibraryFolder {
    #Unique<LibraryFolder>([\.path])
    var path: String
    var name: String
    var bookmark: Data
    var addedAt: Date = Date()

    init(path: String, name: String, bookmark: Data) {
        self.path = path
        self.name = name
        self.bookmark = bookmark
    }

    /// 还原目录 URL；stale 时尝试重建书签
    func resolve() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale, let fresh = try? url.bookmarkData() {
            bookmark = fresh
        }
        return url
    }
}
