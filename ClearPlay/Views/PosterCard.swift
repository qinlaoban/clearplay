import SwiftUI

/// 海报卡片：2:3 海报、hover 浮现播放钮（仅背景/阴影变化，无位移）、底部 3pt 进度条
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 150
    /// 播放按钮点击
    var onPlay: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster

            Text(item.displayTitle)
                .font(.cpBodyMed)
                .foregroundStyle(.cpText)
                .lineLimit(1)

            subtitle
                .font(.cpCaption)
                .foregroundStyle(.cpTextSubtle)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovered = $0 }
        #endif
    }

    private var poster: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: item.artworkURL(item.posterFile))
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    // 未刮削时用首字母占位
                    if item.posterFile == nil {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.cpSurfaceHi)
                            .overlay {
                                Text(initialLetter)
                                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.cpTextSubtle)
                            }
                    }
                }

            if item.inProgress {
                GeometryReader { geo in
                    Capsule()
                        .fill(.black.opacity(0.45))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.cpCTA)
                                .frame(width: geo.size.width * progressFraction)
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, 0)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.cpSurfaceHi : Color.cpSurface)
                .shadow(color: hovered ? .black.opacity(0.45) : .clear, radius: 10)
                .animation(.easeInOut(duration: 0.2), value: hovered)
        )
        .overlay(alignment: .center) {
            playOverlay
        }
    }

    private var playOverlay: some View {
        Group {
            if hovered {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.cpCTA))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hovered)
    }

    private var progressFraction: CGFloat {
        guard item.durationSeconds > 0 else { return 0 }
        return min(CGFloat(item.resumeSeconds / item.durationSeconds), 1)
    }

    private var initialLetter: String {
        String(item.displayTitle.prefix(1)).uppercased()
    }

    @ViewBuilder
    private var subtitle: some View {
        if item.kind == .episode, let s = item.season, let e = item.episodeNumber {
            Text("第 \(s) 季 第 \(e) 集")
        } else if let y = item.year {
            Text(String(y))
        } else {
            Text("未刮削")
        }
    }
}
