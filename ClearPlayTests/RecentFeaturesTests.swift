import XCTest
@testable import ClearPlay_macOS

/// 近期功能补测：RemoteAuthStore 前缀鉴权匹配、库浏览排序规则
@MainActor
final class RecentFeaturesTests: XCTestCase {
    private var createdServers: [WebDAVServer] = []

    override func tearDown() {
        // 清 Keychain 密码 + 复位全局鉴权表，避免污染其他测试
        for server in createdServers { server.destroy() }
        createdServers.removeAll()
        RemoteAuthStore.reload(servers: [])
    }

    private func makeServer(base: String, user: String, pass: String) -> WebDAVServer {
        let server = WebDAVServer(name: "test-\(UUID().uuidString)", baseURL: base, username: user)
        server.password = pass
        createdServers.append(server)
        return server
    }

    // MARK: - RemoteAuthStore

    func testLongestPrefixWins() throws {
        let root = makeServer(base: "https://dav.example.com", user: "root", pass: "rp")
        let sub = makeServer(base: "https://dav.example.com/dav", user: "sub", pass: "sp")
        RemoteAuthStore.reload(servers: [root, sub])

        let headers = RemoteAuthStore.headers(for: URL(string: "https://dav.example.com/dav/Movie.mkv")!)
        let expectedSub = "Basic " + Data("sub:sp".utf8).base64EncodedString()
        XCTAssertEqual(headers["Authorization"], expectedSub, "应命中更长的 /dav 前缀")

        let otherHeaders = RemoteAuthStore.headers(for: URL(string: "https://dav.example.com/other.mkv")!)
        let expectedRoot = "Basic " + Data("root:rp".utf8).base64EncodedString()
        XCTAssertEqual(otherHeaders["Authorization"], expectedRoot, "非 /dav 路径应命中根服务器")
    }

    func testNoMatchingServerReturnsEmptyHeaders() {
        RemoteAuthStore.reload(servers: [])
        let headers = RemoteAuthStore.headers(for: URL(string: "https://elsewhere.host/file.mp4")!)
        XCTAssertTrue(headers.isEmpty)
    }

    func testAnonymousServerIsSkipped() {
        let anon = WebDAVServer(name: "anon", baseURL: "https://anon.example.com", username: "")
        RemoteAuthStore.reload(servers: [anon])

        let headers = RemoteAuthStore.headers(for: URL(string: "https://anon.example.com/a.mkv")!)
        XCTAssertTrue(headers.isEmpty, "匿名（无用户名密码）服务器不应产生鉴权头")
    }

    // MARK: - LibrarySort

    private func makeItem(
        _ title: String, year: Int? = nil, rating: Double? = nil,
        addedOffset: TimeInterval = 0
    ) -> MediaItem {
        let parsed = FilenameParser.parse("\(title).mkv")
        let item = MediaItem(path: "/tmp/\(UUID().uuidString).mkv", folderPath: "", parsed: parsed)
        item.year = year
        item.rating = rating
        item.addedAt = Date(timeIntervalSinceNow: addedOffset)
        return item
    }

    func testSortByTitleUsesDisplayName() {
        let sorted = LibrarySort.title.sorted([makeItem("Zeta"), makeItem("Alpha"), makeItem("Beta")])
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "Beta", "Zeta"])
    }

    func testSortByYearPutsNilLast() {
        let sorted = LibrarySort.year.sorted([
            makeItem("Old", year: 1999), makeItem("NoYear"), makeItem("New", year: 2024),
        ])
        XCTAssertEqual(sorted.compactMap(\.year), [2024, 1999], "无年份应沉底")
    }

    func testSortByRatingPutsNilLast() {
        let sorted = LibrarySort.rating.sorted([
            makeItem("Mid", rating: 6.5), makeItem("Unrated"), makeItem("Top", rating: 9.1),
        ])
        XCTAssertEqual(sorted.compactMap(\.rating), [9.1, 6.5], "未评分应沉底")
    }

    func testSortByRecentPutsNewestFirst() {
        let sorted = LibrarySort.recent.sorted([
            makeItem("OldAdd", addedOffset: -100),
            makeItem("Newest", addedOffset: 0),
            makeItem("Middle", addedOffset: -50),
        ])
        XCTAssertEqual(sorted.map(\.title), ["Newest", "Middle", "OldAdd"])
    }
}
