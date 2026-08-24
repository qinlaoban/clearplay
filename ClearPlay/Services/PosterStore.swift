import Foundation

/// 海报/背景图本地缓存管理：存放在 Caches/ClearPlay/Artwork
enum PosterStore {
    static let cachesDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ClearPlay/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 生成规范化的缓存文件名（不含扩展名，下载时按实际格式追加）
    static func fileName(tmdbID: Int, kind: String) -> String {
        "\(tmdbID)-\(kind)"
    }

    static func localURL(for name: String) -> URL {
        cachesDirectory.appendingPathComponent(name)
    }

    static func exists(_ name: String?) -> Bool {
        guard let name else { return false }
        return FileManager.default.fileExists(atPath: localURL(for: name).path)
    }

    /// 删除缓存文件（条目移除时调用）
    static func remove(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: localURL(for: name))
    }
}
