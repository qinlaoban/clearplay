import XCTest
import SwiftData
@testable import ClearPlay_macOS

/// 媒体库视图模型测试：单文件导入/去重/目录扫描入库与清理
@MainActor
final class MediaLibraryViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var vm: MediaLibraryViewModel!
    private var tempDir: URL!
    private var savedAPIKey: String?

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: MediaItem.self, LibraryFolder.self, configurations: config
        )
        vm = MediaLibraryViewModel(container: container)

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-medialib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 测试期间禁用 TMDB 网络刮削
        savedAPIKey = UserDefaults.standard.string(forKey: "tmdbApiKey")
        UserDefaults.standard.set("", forKey: "tmdbApiKey")
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(savedAPIKey, forKey: "tmdbApiKey")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func touch(_ relative: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    // MARK: - 单文件导入

    func testAddFilesImportsAndParses() async throws {
        let url = try touch("Great.Movie.2021.1080p.mkv")
        let context = container.mainContext

        // onFilesImported 在异步补时长/刮削之后才回调，轮询等待
        var imported: MediaItem?
        vm.onFilesImported = { imported = $0 }
        vm.addFiles(urls: [url])

        let exp = expectation(description: "imported callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 5)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Great Movie")
        XCTAssertEqual(items[0].year, 2021)
        XCTAssertEqual(imported?.path, url.path)
    }

    func testAddFilesDeduplicatesSamePath() throws {
        let url = try touch("dup.mp4")
        vm.addFiles(urls: [url])
        vm.addFiles(urls: [url]) // 重复导入应忽略

        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 1)
    }

    func testAddFilesRejectsNonVideoExtensions() throws {
        let txt = try touch("readme.txt")
        vm.addFiles(urls: [txt])

        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertTrue(items.isEmpty)
        XCTAssertNotNil(vm.lastError)
    }

    /// 散装导入的文件（folderPath 为空）不应被目录重扫清掉
    func testLooseFilesSurviveRescan() async throws {
        // 散装文件放在资料库目录之外
        let looseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-loose-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: looseURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: looseURL) }

        vm.addFiles(urls: [looseURL])
        _ = try touch("in-folder.mp4")
        insertFolder(path: tempDir.path)

        await vm.scanAndScrape()

        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<MediaItem>())
            .contains { $0.path == looseURL.path })
    }

    // MARK: - 目录扫描

    func testScanUpsertsNewFilesOnly() async throws {
        _ = try touch("Movie.One.2001.mkv")
        _ = try touch("Movie.Two.2002.mkv")
        insertFolder(path: tempDir.path)

        await vm.scanAndScrape()
        var items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 2)

        // 新增一个文件再扫，不产生重复
        _ = try touch("Movie.Three.2003.mkv")
        await vm.scanAndScrape()
        items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 3)
    }

    func testScanRemovesStaleRecords() async throws {
        let file = try touch("To.Be.Deleted.mkv")
        insertFolder(path: tempDir.path)

        await vm.scanAndScrape()
        var items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 1)

        // 文件删除后重扫，记录应被清理
        try FileManager.default.removeItem(at: file)
        await vm.scanAndScrape()
        items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertTrue(items.isEmpty)
    }

    func testRemoveFolderDeletesItsItems() async throws {
        _ = try touch("Belongs.To.Folder.mkv")
        vm.addFolder(url: tempDir)
        let exp = expectation(description: "scan")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 5)

        var items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 1)

        let folders = try container.mainContext.fetch(FetchDescriptor<LibraryFolder>())
        XCTAssertEqual(folders.count, 1)
        vm.removeFolder(folders[0])

        items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertTrue(items.isEmpty)
        let remainingFolders = try container.mainContext.fetch(FetchDescriptor<LibraryFolder>())
        XCTAssertTrue(remainingFolders.isEmpty)
    }

    func testDuplicateFolderIgnored() async throws {
        vm.addFolder(url: tempDir)
        vm.addFolder(url: tempDir) // 重复添加应忽略

        let folders = try container.mainContext.fetch(FetchDescriptor<LibraryFolder>())
        XCTAssertEqual(folders.count, 1)
    }

    // MARK: - 辅助

    private func insertFolder(path: String) {
        let ctx = container.mainContext
        guard let data = try? URL(fileURLWithPath: path).bookmarkData() else {
            XCTFail("bookmark 失败")
            return
        }
        ctx.insert(LibraryFolder(path: path, name: "test", bookmark: data))
        try? ctx.save()
    }
}
