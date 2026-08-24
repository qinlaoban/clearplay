import SwiftUI

/// 继续观看横滑行：16:9 缩略卡片 + 剩余时间角标
struct ContinueWatchingRow: View {
    let items: [MediaItem]
    var onPlay: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("继续观看")
                .font(.cpHeading)
                .foregroundStyle(.cpText)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        ContinueWatchingCard(item: item, onPlay: onPlay)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 剩余时间文案（"剩 23 分钟"/"1 小时 5 分"）
    private func remainingLabel(for item: MediaItem) -> String? {
        guard item.durationSeconds > item.resumeSeconds else { return nil }
        let remain = item.durationSeconds - item.resumeSeconds
        let minutes = Int(remain / 60)
        if minutes < 60 { return "剩 \(max(minutes, 1)) 分钟" }
        return String(format: "剩 %d 小时 %02d 分", minutes / 60, minutes % 60)
    }
}

/// 继续观看卡片：NavigationLink 进详情，播放钮在链接外层（hover 浮现），避免嵌套触发
struct ContinueWatchingCard: View {
    let item: MediaItem
    var onPlay: (MediaItem) -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationLink(value: item) {
                cardVisual
            }
            .buttonStyle(.plain)

            Button(action: { onPlay(item) }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.cpCTA))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            .buttonStyle(.plain)
            .padding(8)
            // macOS 悬停浮现；iOS 无悬停，常显
            #if os(macOS)
            .opacity(hovered ? 1 : 0)
            #endif
            .help("播放")
        }
        #if os(macOS)
        .onHover { hovered = $0 }
        #endif
    }

    private var cardVisual: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ArtworkImage(url: item.artworkURL(item.backdropFile) ?? item.artworkURL(item.posterFile))
                    .frame(width: 260, height: 146)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // 剩余时间角标
                if let remaining = remainingLabel(for: item) {
                    Text(remaining)
                        .font(.cpCaption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .foregroundStyle(.cpText)
                        .padding(6)
                }
            }

            Text(item.displayTitle)
                .font(.cpBodyMed)
                .foregroundStyle(.cpText)
                .lineLimit(1)
        }
        .frame(width: 260, alignment: .leading)
    }

    private func remainingLabel(for item: MediaItem) -> String? {
        guard item.durationSeconds > item.resumeSeconds else { return nil }
        let remain = item.durationSeconds - item.resumeSeconds
        let minutes = Int(remain / 60)
        if minutes < 60 { return "剩 \(max(minutes, 1)) 分钟" }
        return String(format: "剩 %d 小时 %02d 分", minutes / 60, minutes % 60)
    }
}
