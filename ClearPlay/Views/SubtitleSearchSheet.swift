import SwiftUI

/// 在线字幕搜索面板：OpenSubtitles 搜索 → 下载 → 挂载到播放器
struct SubtitleSearchSheet: View {
    let videoURL: URL
    let onPicked: (URL, String, String?) -> Void   // (本地文件, 名称, 语言)
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var seasonText = ""
    @State private var episodeText = ""
    @State private var results: [OpenSubtitlesClient.SearchResult] = []
    @State private var isSearching = false
    @State private var isDownloadingID: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    // 从文件名预填搜索词与季集号
    private struct Prefill {
        var title: String
        var season: Int?
        var episode: Int?
    }
    private var prefill: Prefill {
        let parsed = FilenameParser.parse(videoURL.lastPathComponent)
        return Prefill(
            title: parsed.seriesName ?? parsed.title,
            season: parsed.season,
            episode: parsed.episodeNumber
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                resultlist
            }
            .navigationTitle("搜索字幕")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear(perform: fillPrefillIfNeeded)
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
    }

    // MARK: - 搜索栏

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("片名关键词", text: $query)
                .textFieldStyle(.plain)
                .onSubmit(search)

            if isEpisode {
                TextField("季", text: $seasonText)
                    .frame(width: 36)
                TextField("集", text: $episodeText)
                    .frame(width: 36)
            }

            Button("搜索") { search() }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
        .padding(12)
    }

    private var isEpisode: Bool {
        prefill.season != nil || !seasonText.isEmpty || !episodeText.isEmpty
    }

    // MARK: - 结果列表

    @ViewBuilder
    private var resultlist: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("搜索失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if results.isEmpty && !isSearching {
            ContentUnavailableView {
                Label("无结果", systemImage: "captions.bbox")
            } description: {
                Text("换个关键词试试")
            }
        } else {
            List(results) { item in
                row(item)
            }
            .overlay {
                if isSearching { ProgressView().controlSize(.large) }
            }
        }
    }

    private func row(_ item: OpenSubtitlesClient.SearchResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.releaseName ?? item.fileName ?? "字幕 #\(item.id)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(languageLabel(item.language))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.cpPrimary.opacity(0.3), in: Capsule())
                    Text("\(item.downloadCount) 次下载")
                    if item.rating > 0 {
                        Label(String(format: "%.1f", item.rating), systemImage: "star.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloadingID == item.id {
                ProgressView()
            } else {
                Button("下载") { download(item) }
                    .disabled(item.fileID == nil)
            }
        }
    }

    private func languageLabel(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized ?? code.uppercased()
    }

    // MARK: - 动作

    private func fillPrefillIfNeeded() {
        let p = prefill
        if query.isEmpty { query = p.title }
        if p.season != nil, seasonText.isEmpty { seasonText = String(p.season!) }
        if p.episode != nil, episodeText.isEmpty { episodeText = String(p.episode!) }
    }

    private func search() {
        searchTask?.cancel()
        errorMessage = nil
        results = []
        isSearching = true
        let q = query.trimmingCharacters(in: .whitespaces)
        let season = Int(seasonText)
        let episode = Int(episodeText)

        searchTask = Task {
            do {
                let client = try await OpenSubtitlesAccount.makeClient()
                let found = try await client.search(query: q, season: season, episode: episode)
                guard !Task.isCancelled else { return }
                results = found.sorted { $0.downloadCount > $1.downloadCount }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func download(_ item: OpenSubtitlesClient.SearchResult) {
        guard let fileID = item.fileID else { return }
        isDownloadingID = item.id
        Task {
            do {
                var client = try await OpenSubtitlesAccount.makeClient()
                let localURL = try await client.download(
                    fileID: fileID,
                    suggestedFileName: item.fileName
                )
                onPicked(localURL, item.releaseName ?? item.fileName ?? "在线字幕", item.language)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDownloadingID = nil
            }
        }
    }
}
