import SwiftUI

/// 继续观看横滑行：16:9 缩略卡片 + 剩余时间角标
struct ContinueWatchingRow: View {
    let items: [MediaItem]
    var onPlay: (MediaItem) -> Void
    var onOpen: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("继续观看")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.cpText)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        card(for: item)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func card(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkImage(url: item.artworkURL(item.backdropFile) ?? item.artworkURL(item.posterFile))
                    .frame(width: 260, height: 146)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let remaining = remainingLabel(for: item) {
                    Text(remaining)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .foregroundStyle(.cpText)
                        .padding(6)
                }

                // 播放覆盖按钮
                Button(action: { onPlay(item) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.cpCTA))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(item) }

            Text(item.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.cpText)
                .lineLimit(1)
        }
        .frame(width: 260, alignment: .leading)
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
