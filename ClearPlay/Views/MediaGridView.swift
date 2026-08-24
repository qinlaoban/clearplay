import SwiftUI
import SwiftData

/// 库浏览排序方式
enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "标题"
    case year = "年份"
    case rating = "评分"
    case recent = "最近添加"

    var id: String { rawValue }
}

/// 通用库浏览（电影 / 剧集 / 收藏）：海报墙网格 + 搜索 + 排序 + 列表视图切换
struct MediaGridView: View {
    @Environment(LibraryViewModel.self) private var library

    let kind: MediaKind
    let title: String
    var favoritesOnly: Bool = false

    @State private var sortOrder: LibrarySort = .title
    @State private var isList = false

    // 注意：Query 的 sort 键必须是持久化属性（displayTitle 是计算属性，会导致运行时崩溃）
    @Query private var allItems: [MediaItem]

    init(kind: MediaKind, title: String) {
        self.kind = kind
        self.title = title
        _allItems = Query(sort: \MediaItem.title)
    }

    /// 收藏视图专用初始化
    init(title: String = "收藏", favoritesOnly: Bool) {
        self.kind = .movie
        self.title = title
        self.favoritesOnly = favoritesOnly
        _allItems = Query(
            filter: #Predicate { $0.favorite == true },
            sort: \MediaItem.title
        )
    }

    /// 过滤 + 排序后的条目
    private var items: [MediaItem] {
        let base = favoritesOnly ? allItems : allItems.filter { $0.kind == kind }
        var result = base
        switch sortOrder {
        case .title:
            result.sort { $0.displayTitle < $1.displayTitle }
        case .year:
            result.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating:
            result.sort { ($0.rating ?? -1) > ($1.rating ?? -1) }
        case .recent:
            result.sort { $0.addedAt > $1.addedAt }
        }
        return result
    }

    var body: some View {
        // body 内多处访问，先求值一次避免重复过滤+排序
        let items = self.items
        return Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(
                        favoritesOnly ? "还没有收藏" : "没有影片",
                        systemImage: "film.stack"
                    )
                } description: {
                    Text(favoritesOnly ? "在详情页点击 ♥ 即可收藏" : "在侧栏添加文件夹以导入影片")
                }
                .background(.cpBackground)
            } else {
                ScrollView {
                    if isList {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                NavigationLink(value: item) {
                                    row(item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("播放") { play(item) }
                                }
                            }
                        }
                        .padding(CPMetrics.pad)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(items) { item in
                                PosterNavigationCard(item: item, onPlay: { play(item) })
                            }
                        }
                        .padding(CPMetrics.pad)
                    }
                }
                .background(.cpBackground)
            }
        }
        .navigationTitle(title)
        // 搜索已由全局搜索（ContentView 工具栏）承担，避免嵌套双搜索框
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("排序", selection: $sortOrder) {
                        ForEach(LibrarySort.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                } label: {
                    Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isList.toggle() }
                } label: {
                    Image(systemName: isList ? "square.grid.2x2" : "list.bullet")
                }
                .help(isList ? "切换为网格视图" : "切换为列表视图")
            }
        }
    }

    /// 列表视图行
    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(url: item.artworkURL(item.posterFile))
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: CPMetrics.radiusSm))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.cpBodyMed)
                    .foregroundStyle(.cpText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let y = item.year { Text(String(y)) }
                    if let r = item.rating {
                        Label(String(format: "%.1f", r), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if item.kind == .episode, let s = item.season, let e = item.episodeNumber {
                        Text("第 \(s) 季 第 \(e) 集")
                    }
                }
                .font(.cpCaption)
                .foregroundStyle(.cpTextSubtle)

                if item.inProgress {
                    ProgressView(value: progressFraction(for: item))
                        .progressViewStyle(.linear)
                        .tint(.cpCTA)
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.cpSmall)
                .foregroundStyle(.cpTextFaint)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: CPMetrics.radiusSm).fill(.cpSurface))
    }

    private func progressFraction(for item: MediaItem) -> Double {
        guard item.durationSeconds > 0 else { return 0 }
        return min(Double(item.resumeSeconds) / Double(item.durationSeconds), 1)
    }

    private func play(_ item: MediaItem) {
        library.play(queue: items, start: item)
    }
}
