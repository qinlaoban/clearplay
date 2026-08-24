import XCTest
import SwiftData
@testable import ClearPlay_macOS

/// MediaQueue / PendingPlay 测试：播放队列构建规则与待播请求总线
@MainActor
final class MediaQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: MediaItem.self, LibraryFolder.self, configurations: config
        )
        context = ModelContext(container)
    }

    private func makeMovie(_ title: String) -> MediaItem {
        let parsed = FilenameParser.parse("\(title).2020.mkv")
        return MediaItem(path: "/tmp/\(UUID().uuidString).mkv", folderPath: "", parsed: parsed)
    }

    private func makeEpisode(series: String, season: Int, episode: Int) -> MediaItem {
        let name = String(format: "%@ S%02dE%02d.mkv", series, season, episode)
        let parsed = FilenameParser.parse(name)
        return MediaItem(path: "/tmp/\(UUID().uuidString).mkv", folderPath: "", parsed: parsed)
    }

    func testMovieQueueContainsAllMoviesSortedByTitle() throws {
        let a = makeMovie("Zeta")
        let b = makeMovie("Alpha")
        let c = makeMovie("Beta")
        let ep = makeEpisode(series: "剧", season: 1, episode: 1)
        [a, b, c, ep].forEach { context.insert($0) }
        try context.save()

        let queue = MediaQueue.build(start: b, context: context)
        XCTAssertEqual(queue.map(\.displayTitle), ["Alpha", "Beta", "Zeta"])
        XCTAssertFalse(queue.contains(where: { $0.kind == .episode }))
    }

    func testEpisodeQueueIsSameSeriesSorted() throws {
        let target = makeEpisode(series: "老友记", season: 2, episode: 1)
        let e1 = makeEpisode(series: "老友记", season: 1, episode: 3)
        let e2 = makeEpisode(series: "老友记", season: 1, episode: 10)
        let other = makeEpisode(series: "另一部剧", season: 1, episode: 1)
        [e1, target, other, e2].forEach { context.insert($0) }
        try context.save()

        let queue = MediaQueue.build(start: target, context: context)
        // 同剧按 (season, episode) 排序；不含其他剧
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.first?.season, 1)
        XCTAssertEqual(queue.last?.season, 2)
        XCTAssertTrue(queue.allSatisfy { $0.seriesName == "老友记" })
    }

    func testFindMatchesLocalPathAndRemoteURL() throws {
        let local = makeMovie("Alpha")
        let remoteParsed = FilenameParser.parse("Remote.Movie.mkv")
        let remote = MediaItem(
            path: "https://dav.example.com/Remote.Movie.mkv",
            folderPath: "webdav:x", parsed: remoteParsed
        )
        context.insert(local)
        context.insert(remote)
        try context.save()

        XCTAssertNotNil(MediaQueue.find(path: local.path, context: context))
        XCTAssertEqual(MediaQueue.find(path: remote.path, context: context)?.path, remote.path)
        XCTAssertNil(MediaQueue.find(path: "/nonexistent.mkv", context: context))
    }

    func testPendingPlayRequestPostsNotification() {
        // 注意：测试宿主是完整 App，其 ContentView 会监听并消费该通知（清空 path），
        // 因此这里只断言通知发出，不断言 path 残留。
        let notified = expectation(forNotification: .clearplayPlayRequested, object: nil)
        PendingPlay.request("/tmp/movie.mkv")
        wait(for: [notified], timeout: 2)
    }

    func testPendingPlayPathStorage() {
        let saved = PendingPlay.path
        defer { PendingPlay.path = saved }
        PendingPlay.path = "/tmp/direct.mkv"
        XCTAssertEqual(PendingPlay.path, "/tmp/direct.mkv")
    }
}
