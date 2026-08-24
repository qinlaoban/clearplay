import Foundation

/// 目录扫描器：递归枚举目录下的视频文件
enum FolderScanner {
    struct ScannedFile {
        let url: URL
    }

    /// 递归扫描目录，返回所有视频文件；跳过隐藏目录与样本文件
    static func scan(folder: URL) throws -> [ScannedFile] {
        var results: [ScannedFile] = []
        // 不跟随符号链接，避免循环
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        )
        while let raw = enumerator?.nextObject() as? URL {
            guard let values = try? raw.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isHidden == true || values.isSymbolicLink == true {
                // 隐藏目录/符号链接整个跳过（含子树）
                enumerator?.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                // 跳过常见垃圾目录
                if ["sample", "extras", "proof"].contains(raw.lastPathComponent.lowercased()) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard FilenameParser.videoExtensions.contains(raw.pathExtension.lowercased()) else { continue }
            if raw.lastPathComponent.lowercased().contains("sample") { continue }
            results.append(ScannedFile(url: raw))
        }
        return results
    }
}
