import SwiftUI

/// 从本地缓存文件加载图片（海报/背景图），NSCache 避免网格滚动时反复解码
struct ArtworkImage: View {
    let url: URL?

    /// 进程级图片缓存
    private static let cache = NSCache<NSString, NSUIImage>()

    var body: some View {
        if let url, let image = Self.load(path: url.path) {
            platformImage(image)
                .resizable()
                .scaledToFill()
        } else {
            nilView
        }
    }

    private var nilView: some View {
        ZStack {
            Rectangle().fill(.cpSurfaceHi)
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.cpTextSubtle)
        }
    }

    /// 读盘 + 内存缓存
    private static func load(path: String) -> NSUIImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let img = NSUIImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }

    private func platformImage(_ img: NSUIImage) -> Image {
        #if canImport(AppKit)
        Image(nsImage: img)
        #else
        Image(uiImage: img)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
typealias NSUIImage = NSImage
#else
import UIKit
typealias NSUIImage = UIImage
#endif
