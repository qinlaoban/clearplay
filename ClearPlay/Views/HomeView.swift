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
        // 最近添加包含所有条目（正在看的也在内，按添加时间倒序）
        Array(allItems.prefix(24))
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
                            onPlay: { play($0) }
                        )
                    }

                    if !recent.isEmpty {
                        Text("最近添加")
                            .font(.cpHeading)
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
                .font(.cpHeading)
                .foregroundStyle(.cpText)

            Text("在侧栏点击「添加文件夹」，ClearPlay 会自动扫描影片并抓取海报")
                .font(.cpBody)
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
                PosterNavigationCard(item: item, onPlay: { play(item) })
            }
        }
    }

    // MARK: - 动作

    /// 播放：队列按条目类型分组——剧集以同剧分集为队列，电影以全部电影为队列
    private func play(_ item: MediaItem) {
        let queue: [MediaItem]
        if item.kind == .episode, let series = item.seriesName {
            queue = allItems
                .filter { $0.kind == .episode && $0.seriesName == series }
                .sorted { ($0.season ?? 0, $0.episodeNumber ?? 0) < ($1.season ?? 0, $1.episodeNumber ?? 0) }
        } else {
            queue = allItems.filter { $0.kind == .movie }.sorted { $0.displayTitle < $1.displayTitle }
        }
        library.play(queue: queue.isEmpty ? [item] : queue, start: item)
    }
}
