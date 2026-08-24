import XCTest
import SwiftData
@testable import ClearPlay_macOS

/// MediaItem 模型逻辑测试：展示标题/续播判定/缓存路径
final class MediaItemTests: XCTestCase {

    private func makeItem(parsed: FilenameParser.Result) -> MediaItem {
        MediaItem(path: "/tmp/\(UUID().uuidString).mp4", folderPath: "", parsed: parsed)
    }

    // MARK: - displayTitle

    func testEpisodeDisplayTitleFormatted() {
        let r = FilenameParser.parse("Some.Show.S01E02.mkv")
        let item = makeItem(parsed: r)
        XCTAssertEqual(item.displayTitle, "Some Show S01E02")
    }

    func testMovieDisplayTitleIsTitle() {
        let r = FilenameParser.parse("Inception.2010.mkv")
        let item = makeItem(parsed: r)
        XCTAssertEqual(item.displayTitle, "Inception")
    }

    /// 分集缺季集号时不崩溃，回退到标题
    func testEpisodeDisplayTitleWithoutNumbers() {
        var r = FilenameParser.parse("Show.S01E02.mkv")
        r.season = nil
        r.episodeNumber = nil
        let item = makeItem(parsed: r)
        XCTAssertEqual(item.displayTitle, "Show")
    }

    // MARK: - inProgress 续播判定

    func testInProgressWhenPartiallyWatched() {
        let item = makeItem(parsed: FilenameParser.parse("a.mp4"))
        item.resumeSeconds = 300
        item.durationSeconds = 1800
        XCTAssertTrue(item.inProgress)
    }

    func testNotInProgressWhenAlmostFinished() {
        let item = makeItem(parsed: FilenameParser.parse("a.mp4"))
        item.resumeSeconds = 1750
        item.durationSeconds = 1800 // 97% > 95%
        XCTAssertFalse(item.inProgress)
    }

    func testNotInProgressWhenBarelyStarted() {
        let item = makeItem(parsed: FilenameParser.parse("a.mp4"))
        item.resumeSeconds = 2
        item.durationSeconds = 1800
        XCTAssertFalse(item.inProgress)
    }

    func testInProgressWhenDurationUnknown() {
        let item = makeItem(parsed: FilenameParser.parse("a.mp4"))
        item.resumeSeconds = 60
        item.durationSeconds = 0
        XCTAssertTrue(item.inProgress)
    }

    // MARK: - artworkURL / PosterStore

    func testArtworkURLBuildsPath() {
        let item = makeItem(parsed: FilenameParser.parse("a.mp4"))
        item.posterFile = "12345-poster.jpg"
        XCTAssertEqual(
            item.artworkURL(item.posterFile),
            PosterStore.cachesDirectory.appendingPathComponent("12345-poster.jpg")
        )
    }

    func testArtworkURLOfNilReturnsNil() {
        let item = makeItem(parsed: FilenameParser.parse("a.mp4"))
        XCTAssertNil(item.artworkURL(nil))
    }

    func testPosterStoreFileNameFormat() {
        XCTAssertEqual(PosterStore.fileName(tmdbID: 42, kind: "poster"), "42-poster")
    }

    // MARK: - SwiftData 存取

    @MainActor
    func testModelRoundtripInMemoryContainer() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: MediaItem.self, LibraryFolder.self, configurations: config
        )
        let ctx = container.mainContext

        let item = makeItem(parsed: FilenameParser.parse("Test.Movie.2020.mkv"))
        item.overview = "剧情简介"
        item.favorite = true
        ctx.insert(item)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].title, "Test Movie")
        XCTAssertEqual(fetched[0].year, 2020)
        XCTAssertTrue(fetched[0].favorite)
        XCTAssertEqual(fetched[0].overview, "剧情简介")
    }
}
