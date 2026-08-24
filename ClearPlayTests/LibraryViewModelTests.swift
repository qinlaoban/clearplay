import XCTest
import SwiftData
@testable import ClearPlay_macOS

/// 播放队列桥接测试：LibraryViewModel.play 的队列/续播注入逻辑
@MainActor
final class LibraryViewModelTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: MediaItem.self, LibraryFolder.self, configurations: config
        )
    }

    private func makeMediaItem(title: String, resume: Double = 0, duration: Double = 0) -> MediaItem {
        let parsed = FilenameParser.parse("\(title).2020.mkv")
        let item = MediaItem(path: "/tmp/libvm-\(UUID().uuidString).mp4", folderPath: "", parsed: parsed)
        item.title = title
        item.resumeSeconds = resume
        item.durationSeconds = duration
        return item
    }

    func testPlayBuildsQueueAndSetsCurrent() {
        let library = LibraryViewModel()
        let a = makeMediaItem(title: "A")
        let b = makeMediaItem(title: "B")
        let c = makeMediaItem(title: "C")

        library.play(queue: [a, b, c], start: b)

        XCTAssertEqual(library.items.count, 3)
        XCTAssertEqual(library.current?.url, b.url)
    }

    /// SwiftData 里的续播位置应注入位置表，供 PlayerView 断点续播
    func testPlayInjectsResumePositions() {
        let library = LibraryViewModel()
        let watched = makeMediaItem(title: "Watched", resume: 123.5)
        let fresh = makeMediaItem(title: "Fresh", resume: 1) // <3s 不算

        library.play(queue: [watched, fresh], start: watched)

        func video(_ m: MediaItem) -> VideoItem { VideoItem(id: UUID(), url: m.url) }
        XCTAssertEqual(library.resumePosition(for: video(watched)), 123.5)
        XCTAssertNil(library.resumePosition(for: video(fresh)))
        XCTAssertNil(library.resumePosition(for: VideoItem(id: UUID(), url: URL(fileURLWithPath: "/nonexistent"))))
    }

    /// 播放位置落盘会触发回调（App 层用它回写 SwiftData）
    func testSavePositionTriggersCallback() {
        let library = LibraryViewModel()
        var callbackURL: URL?
        var callbackSeconds: Double?
        library.onPositionSave = { url, seconds in
            callbackURL = url
            callbackSeconds = seconds
        }
        let item = VideoItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/x.mp4"))

        library.savePosition(for: item, seconds: 42)

        XCTAssertEqual(callbackURL?.path, "/tmp/x.mp4")
        XCTAssertEqual(callbackSeconds, 42)
        XCTAssertEqual(library.resumePosition(for: item), 42)
    }

    /// 队列步进：上一首/下一首，越界返回 nil
    func testStepWithinQueue() {
        let library = LibraryViewModel()
        let a = makeMediaItem(title: "A")
        let b = makeMediaItem(title: "B")
        library.play(queue: [a, b], start: a)

        let va = VideoItem(id: UUID(), url: a.url)
        let vb = VideoItem(id: UUID(), url: b.url)
        XCTAssertEqual(library.step(from: va, offset: 1)?.url, vb.url)
        XCTAssertEqual(library.step(from: vb, offset: -1)?.url, va.url)
        XCTAssertNil(library.step(from: va, offset: -1))
        XCTAssertNil(library.step(from: vb, offset: 1))
    }
}
