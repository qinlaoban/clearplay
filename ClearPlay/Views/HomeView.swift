import SwiftUI
import SwiftData

/// 首页：继续观看 + 最近添加 + 空状态引导
struct HomeView: View {
    @Environment(LibraryViewModel.self) private var library
    @Query(sort: \MediaItem.addedAt, order: .reverse) private var allItems: [MediaItem]

    private var continueWatching: [MediaItem] {
        allItems
            .filter { $0.inProgress }
            .sorted { ($0.playedAt ?? .distantPast) > ($1.playedAt ?? .distantPast) }
    }

    private var recent: [MediaItem] {
        Array(allItems.filter { !$0.inProgress }.prefix(24))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if continueWatching.isEmpty && recent.isEmpty {
                    emptyState
                } else {
                    if !continueWatching.isEmpty {
                        ContinueWatchingRow(
                            items: continueWatching,
                            onPlay: { play($0) },
                            onOpen: { _ in } // 卡片整体由 NavigationLink 承载
                        )
                    }

                    if !recent.isEmpty {
                        Text("最近添加")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.cpText)
                        posterWall(recent)
                    }
                }
            }
            .padding(24)
        }
        .background(.cpBackground)
        .navigationTitle("首页")
    }

    // MARK: - 子视图

    /// 空状态：引导添加资料库目录（shimmer 占位）
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.cpTextSubtle)

            Text("媒体库是空的")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.cpText)

            Text("在侧栏点击「添加文件夹」，ClearPlay 会自动扫描影片并抓取海报")
                .font(.system(size: 13))
                .foregroundStyle(.cpTextSubtle)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.cpSurface)
                        .frame(width: 100, height: 150)
                        .shimmer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    /// 海报墙网格：卡片整体 NavigationLink 进详情
    private func posterWall(_ items: [MediaItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item, onPlay: { play(item) })
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 动作

    /// 播放：以全部条目（按标题排序）为队列
    private func play(_ item: MediaItem) {
        let queue = allItems.sorted { $0.displayTitle < $1.displayTitle }
        library.play(queue: queue, start: item)
    }
}
