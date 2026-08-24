import SwiftUI
import SwiftData

/// 详情页：全宽背景图 + 渐变压黑、播放/收藏/重新匹配、剧集分集列表
struct MediaDetailView: View {
    @Environment(LibraryViewModel.self) private var library
    @Environment(MediaLibraryViewModel.self) private var media
    @Environment(\.modelContext) private var context

    let item: MediaItem

    @Query private var episodes: [MediaItem]
    @State private var selectedSeason: Int = 1

    init(item: MediaItem) {
        self.item = item
        if item.kind == .episode, let series = item.seriesName {
            _episodes = Query(
                filter: #Predicate {
                    $0.seriesName == series && $0.kindRaw == "episode"
                },
                sort: [SortDescriptor(\.season), SortDescriptor(\.episodeNumber)]
            )
        } else {
            // 电影：查询结果不使用
            _episodes = Query(filter: #Predicate { $0.kindRaw == "___none___" })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backdrop

                VStack(alignment: .leading, spacing: 16) {
                    headerInfo
                    actionRow

                    if item.overview?.isEmpty == false || item.overview != nil {
                        Text(item.overview!)
                            .font(.cpBody)
                            .foregroundStyle(.cpTextSubtle)
                            .lineSpacing(4)
                    }

                    if item.kind == .episode && !seasons.isEmpty {
                        episodeSection
                    }
                }
                .padding(24)
            }
        }
        .background(.cpBackground)
        .navigationTitle(item.displayTitle)
    }

    // MARK: - 背景图

    private var backdrop: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: item.artworkURL(item.backdropFile) ?? item.artworkURL(item.posterFile))
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .clipped()

            LinearGradient(
                colors: [.cpBackground.opacity(0), .cpBackground.opacity(0), .cpBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - 信息区

    private var headerInfo: some View {
        HStack(alignment: .top, spacing: 18) {
            ArtworkImage(url: item.artworkURL(item.posterFile))
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.4), radius: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.cpTitle)
                    .foregroundStyle(.cpText)

                HStack(spacing: 8) {
                    if let y = item.year { Text(String(y)) }
                    if let r = item.rating {
                        separator
                        Label(String(format: "%.1f", r), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if item.durationSeconds > 0 {
                        separator
                        Text(Format.duration(item.durationSeconds))
                    }
                    if item.kind == .episode {
                        separator
                        Text("剧集")
                    }
                }
                .font(.cpSmall)
                .foregroundStyle(.cpTextSubtle)

                if item.tmdbID == nil {
                    Label("未刮削元数据", systemImage: "sparkles")
                        .font(.cpCaption)
                        .foregroundStyle(.cpTextSubtle)
                }
            }
            Spacer()
        }
    }

    /// 信息行分隔符（年份 · 评分 · 时长）
    private var separator: some View {
        Text("·")
            .foregroundStyle(.cpTextFaint)
    }

    /// 播放 / 收藏 / 重新匹配
    private var actionRow: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Label(item.inProgress ? "继续播放" : "播放", systemImage: "play.fill")
                    .font(.cpButton)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.cpCTA))
            }
            .buttonStyle(.plain)

            Button {
                item.favorite.toggle()
                try? context.save()
            } label: {
                Image(systemName: item.favorite ? "heart.fill" : "heart")
                    .font(.cpControl)
                    .foregroundStyle(item.favorite ? .red : .cpTextSubtle)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.cpSurfaceHi))
            }
            .buttonStyle(.plain)

            Menu {
                Button("重新匹配 TMDB") {
                    Task { await media.rescrape(item) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.cpControl)
                    .foregroundStyle(.cpTextSubtle)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.cpSurfaceHi))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - 剧集区

    private var seasons: [Int] {
        Array(Set(episodes.compactMap(\.season))).sorted()
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("季", selection: $selectedSeason) {
                ForEach(seasons, id: \.self) { s in
                    Text("第 \(s) 季").tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 默认选中当前条目所在季，其次最小季
            .onAppear {
                if let s = item.season, seasons.contains(s) {
                    selectedSeason = s
                } else if let first = seasons.first {
                    selectedSeason = first
                }
            }
            .onChange(of: seasons) { _, newValue in
                if !newValue.contains(selectedSeason), let first = newValue.first {
                    selectedSeason = first
                }
            }

            let list = episodes.filter { $0.season == selectedSeason }
            LazyVStack(spacing: 8) {
                ForEach(list) { ep in
                    NavigationLink(value: ep) {
                        EpisodeRow(item: ep)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 动作

    private func play() {
        if item.kind == .episode {
            library.play(queue: episodes, start: item)
        } else {
            library.play(queue: [item], start: item)
        }
    }
}

/// 分集行：序号 + 标题 + 进度
struct EpisodeRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .center) {
                ArtworkImage(url: item.artworkURL(item.backdropFile) ?? item.artworkURL(item.posterFile))
                    .frame(width: 130, height: 73)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("第 \(item.episodeNumber ?? 0) 集 · \(item.title)")
                    .font(.cpBodyMed)
                    .foregroundStyle(.cpText)
                    .lineLimit(1)

                if item.durationSeconds > 0 {
                    Text(Format.duration(item.durationSeconds))
                        .font(.cpCaption.monospacedDigit())
                        .foregroundStyle(.cpTextSubtle)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.cpSurface))
    }
}
