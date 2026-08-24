import Foundation

/// 视频条目模型
struct VideoItem: Identifiable, Hashable {
    let id: UUID
    let url: URL

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }
}
