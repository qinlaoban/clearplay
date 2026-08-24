import AppIntents
import SwiftData
import CoreSpotlight
import UniformTypeIdentifiers

/// App Intents / Spotlight 引用的媒体实体（id = MediaItem.path）
struct MediaEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "影片"
    static let defaultQuery = MediaEntityQuery()

    /// MediaItem.path（本地文件路径或远程 URL 字符串）
    var id: String
    var displayTitle: String
    var kindRaw: String
    var overview: String?
    var rating: Double?
    var posterFile: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayTitle)", image: .init(systemName: iconName))
    }

    var iconName: String { kindRaw == "episode" ? "tv" : "film" }

    init(item: MediaItem) {
        self.id = item.path
        self.displayTitle = item.displayTitle
        self.kindRaw = item.kindRaw
        self.overview = item.overview
        self.rating = item.rating
        self.posterFile = item.posterFile
    }
}

/// 实体查询：从共享容器读取，供快捷指令参数选择/补全
struct MediaEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MediaEntity] {
        let context = ModelContext(AppDatabase.shared)
        return try context.fetch(FetchDescriptor<MediaItem>())
            .filter { identifiers.contains($0.path) }
            .map(MediaEntity.init)
    }

    func entities(matching string: String) async throws -> [MediaEntity] {
        let context = ModelContext(AppDatabase.shared)
        return try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
            .filter { $0.displayTitle.localizedCaseInsensitiveContains(string) }
            .prefix(20)
            .map(MediaEntity.init)
    }

    func suggestedEntities() async throws -> [MediaEntity] {
        let context = ModelContext(AppDatabase.shared)
        return try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
            .prefix(10)
            .map(MediaEntity.init)
    }
}

/// 播放指定影片（快捷指令 / Siri / Spotlight 动作）
struct PlayMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "播放影片"
    static let description = IntentDescription("在 ClearPlay 中播放指定影片")
    static let openAppWhenRun = true

    @Parameter(title: "影片") var target: MediaEntity

    init() {}

    init(target: MediaEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingPlay.request(target.id)
        return .result(dialog: "正在播放 \(target.displayTitle)")
    }
}

/// 继续观看最近未看完的影片
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "继续观看"
    static let description = IntentDescription("继续播放上次未看完的影片")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(AppDatabase.shared)
        let items = try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)]))
        guard let target = items.first(where: { $0.inProgress }) else {
            return .result(dialog: "没有正在看的影片")
        }
        PendingPlay.request(target.path)
        return .result(dialog: "继续播放 \(target.displayTitle)")
    }
}

/// 应用快捷方式（Spotlight 短语 / Siri 建议）
struct ClearPlayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: [
                "用\(.applicationName)继续看",
                "在\(.applicationName)里继续播放"
            ],
            shortTitle: "继续观看",
            systemImageName: "play.circle"
        )
    }
}
