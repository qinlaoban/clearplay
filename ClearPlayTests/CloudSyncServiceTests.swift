import XCTest
import CloudKit
import SwiftData
@testable import ClearPlay_macOS

/// CloudKit 续播同步测试：记录名哈希 / 记录解析 / 远端更新合并规则
@MainActor
final class CloudSyncServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: MediaItem.self, LibraryFolder.self, configurations: config
        )
        context = ModelContext(container)
    }

    func testRecordNameIsStableAndValid() {
        let path = "/Users/qin/Movies/老友记 S01E01.mkv"
        let a = CloudSyncService.recordName(for: path)
        let b = CloudSyncService.recordName(for: path)
        // 稳定：同一路径两次哈希一致
        XCTAssertEqual(a, b)
        // 合法：64 位十六进制，远小于 255 字符限制
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
        // 不同路径不碰撞
        XCTAssertNotEqual(a, CloudSyncService.recordName(for: "/other/file.mp4"))
    }

    func testUpdateParsingFromRecord() throws {
        let record = CKRecord(recordType: CloudSyncService.recordType,
                              recordID: CKRecord.ID(recordName: "abc"))
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        record["mediaPath"] = "/tmp/movie.mkv" as NSString
        record["position"] = 123.5 as NSNumber
        record["updatedAt"] = date as NSDate

        let update = CloudSyncService.update(from: record)
        XCTAssertNotNil(update)
        XCTAssertEqual(update?.path, "/tmp/movie.mkv")
        XCTAssertEqual(update?.position ?? 0, 123.5, accuracy: 0.001)
        XCTAssertEqual(update?.updatedAt.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.001)

        // 缺字段返回 nil
        let broken = CKRecord(recordType: CloudSyncService.recordType,
                              recordID: CKRecord.ID(recordName: "def"))
        broken["mediaPath"] = "/x.mkv" as NSString
        XCTAssertNil(CloudSyncService.update(from: broken))
    }

    private func insertItem(path: String) -> MediaItem {
        let parsed = FilenameParser.parse("Movie.2020.mkv")
        let item = MediaItem(path: path, folderPath: "", parsed: parsed)
        context.insert(item)
        return item
    }

    func testApplyOverwritesLocalWhenRemoteNewer() throws {
        let localDate = Date(timeIntervalSince1970: 1_700_000_000)
        let remoteDate = Date(timeIntervalSince1970: 1_800_000_000)
        let item = insertItem(path: "/a.mkv")
        item.resumeSeconds = 10
        item.playedAt = localDate
        try context.save()

        CloudSyncService.apply(
            [PlaybackUpdate(path: "/a.mkv", position: 600, updatedAt: remoteDate)],
            to: context
        )
        // 远端较新 → 覆盖并回退 3 秒衔接
        XCTAssertEqual(item.resumeSeconds, 597, accuracy: 0.001)
        XCTAssertEqual(item.playedAt, remoteDate)
    }

    func testApplyKeepsLocalWhenRemoteOlderOrMissing() throws {
        let newerLocal = Date(timeIntervalSince1970: 1_900_000_000)
        let olderRemote = Date(timeIntervalSince1970: 1_800_000_000)

        let watched = insertItem(path: "/local-newer.mkv")
        watched.resumeSeconds = 500
        watched.playedAt = newerLocal

        CloudSyncService.apply(
            [PlaybackUpdate(path: "/local-newer.mkv", position: 100, updatedAt: olderRemote),
             PlaybackUpdate(path: "/not-in-library.mkv", position: 50, updatedAt: olderRemote)],
            to: context
        )
        // 本地较新 → 不覆盖；库里没有的路径 → 忽略
        XCTAssertEqual(watched.resumeSeconds, 500, accuracy: 0.001)
    }

    func testApplyTreatsNeverPlayedItemAsUpdatable() throws {
        let item = insertItem(path: "/fresh.mkv")
        item.playedAt = nil

        CloudSyncService.apply(
            [PlaybackUpdate(path: "/fresh.mkv", position: 300, updatedAt: Date())],
            to: context
        )
        XCTAssertEqual(item.resumeSeconds, 297, accuracy: 0.001)
        XCTAssertNotNil(item.playedAt)
    }
}
