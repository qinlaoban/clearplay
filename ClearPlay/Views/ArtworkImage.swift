import SwiftUI

/// 从本地缓存文件加载图片（海报/背景图）
struct ArtworkImage: View {
    let url: URL?

    var body: some View {
        if let url, let image = loadPlatformImage(path: url.path) {
            image
                .resizable()
                .scaledToFill()
        } else {
            nilView
        }
    }

    private func loadPlatformImage(path: String) -> Image? {
        guard let img = NSUIImage(contentsOfFile: path) else { return nil }
        #if canImport(AppKit)
        return Image(nsImage: img)
        #else
        return Image(uiImage: img)
        #endif
    }

    private var nilView: some View {
        ZStack {
            Rectangle().fill(.cpSurfaceHi)
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.cpTextSubtle)
        }
    }
}

#if canImport(AppKit)
import AppKit
typealias NSUIImage = NSImage
#else
import UIKit
typealias NSUIImage = UIImage
#endif
