import XCTest
@testable import ClearPlay_macOS

/// 目录扫描器测试：递归/扩展名过滤/隐藏文件/sample 跳过
final class FolderScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

    func testRecursiveScanFindsNestedVideos() throws {
        _ = try touch("Movies/a.mp4")
        _ = try touch("TV/Season 1/b.mkv")
        _ = try touch("root.mov")

        let results = try FolderScanner.scan(folder: tempDir)
        XCTAssertEqual(results.count, 3)
    }

    func testNonVideoExtensionsExcluded() throws {
        _ = try touch("a.mp4")
        _ = try touch("notes.txt")
        _ = try touch("cover.jpg")
        _ = try touch("subs.srt")
        _ = try touch("script.nfo")

        let results = try FolderScanner.scan(folder: tempDir)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].url.lastPathComponent == "a.mp4")
    }

    func testHiddenFilesSkipped() throws {
        _ = try touch("a.mp4")
        _ = try touch(".hidden/b.mp4") // 隐藏目录内的视频

        let results = try FolderScanner.scan(folder: tempDir)
        XCTAssertEqual(results.count, 1)
    }

    func testSampleDirectorySkipped() throws {
        _ = try touch("a.mp4")
        _ = try touch("Sample/c.mp4")   // 垃圾目录不递归
        _ = try touch("sample-file.mp4") // 文件名含 sample 也跳过

        let results = try FolderScanner.scan(folder: tempDir)
        XCTAssertEqual(results.count, 1)
    }
}
