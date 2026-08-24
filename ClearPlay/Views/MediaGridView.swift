import SwiftUI
import SwiftData

/// 通用海报墙网格（电影 / 剧集 / 收藏）
struct MediaGridView: View {
    @Environment(LibraryViewModel.self) private var library

    let kind: MediaKind
    let title: String
    var favoritesOnly: Bool = false

    @Query private var allItems: [MediaItem]

    init(kind: MediaKind, title: String) {
        self.kind = kind
        self.title = title
        _allItems = Query(sort: \MediaItem.displayTitle)
    }

    /// 收藏视图专用初始化
    init(title: String = "收藏", favoritesOnly: Bool) {
        self.kind = .movie
        self.title = title
        self.favoritesOnly = favoritesOnly
        _allItems = Query(
            filter: #Predicate { $0.favorite == true },
            sort: \MediaItem.displayTitle
        )
    }

    private var items: [MediaItem] {
        favoritesOnly ? allItems : allItems.filter { $0.kind == kind }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(favoritesOnly ? "还没有收藏" : "没有影片", systemImage: "film.stack")
                } description: {
                    Text(favoritesOnly ? "在详情页点击 ♥ 即可收藏" : "在侧栏添加文件夹以导入影片")
                }
                .background(.cpBackground)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item, onPlay: { play(item) })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
                .background(.cpBackground)
            }
        }
        .navigationTitle(title)
    }

    private func play(_ item: MediaItem) {
        library.play(queue: items.sorted { $0.displayTitle < $1.displayTitle }, start: item)
    }
}
