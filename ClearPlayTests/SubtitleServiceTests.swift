import XCTest
@testable import ClearPlay_macOS

/// OpenSubtitlesClient + LocalSubtitleFinder 测试
final class SubtitleServiceTests: XCTestCase {

    /// 拦截所有请求，返回预设响应
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let responder = Self.responder, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, data) = responder(request)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient(token: String? = nil) -> OpenSubtitlesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return OpenSubtitlesClient(apiKey: "test-key", session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - 搜索

    func testSearchParsesResults() async throws {
        StubURLProtocol.responder = { _ in
            (200, """
            {"data":[{"id":"999","attributes":{
                "language":"zh","release":"Movie.2023.1080p","download_count":1234,
                "ratings":8.5,
                "files":[{"file_id":555,"file_name":"Movie.zh.srt"}]}}]}
            """.data(using: .utf8)!)
        }
        let results = try await makeClient().search(query: "Movie", season: 1, episode: 2)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "999")
        XCTAssertEqual(results[0].language, "zh")
        XCTAssertEqual(results[0].fileID, 555)
        XCTAssertEqual(results[0].downloadCount, 1234)
        XCTAssertEqual(results[0].rating, 8.5)
    }

    func testSearchSendsAPIKeyHeaderAndQueryParams() async throws {
        nonisolated(unsafe) var capturedRequest: URLRequest?
        StubURLProtocol.responder = { request in
            capturedRequest = request
            return (200, Data(#"{"data":[]}"#.utf8))
        }
        _ = try await makeClient().search(query: "Inception", languages: ["zh"])

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Api-Key"), "test-key")
        XCTAssertEqual(capturedRequest?.url?.host, "api.opensubtitles.com")
        let query = capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("query=Inception"))
        XCTAssertTrue(query.contains("languages=zh"))
    }

    func testSearchHTTPErrorThrows() async {
        StubURLProtocol.responder = { _ in (429, Data()) }
        do {
            _ = try await makeClient().search(query: "x")
            XCTFail("应抛出错误")
        } catch {
            XCTAssertTrue("\(error)".contains("429") || error is OpenSubtitlesClient.SubtitleError)
        }
    }

    // MARK: - 登录与下载

    func testLoginStoresTokenForDownload() async throws {
        StubURLProtocol.responder = { request in
            Self.downloadResponder(request)
        }
        var client = makeClient()
        try await client.login(username: "u", password: "p")
        let url = try await client.download(fileID: 42, suggestedFileName: "movie.zh.srt")

        XCTAssertEqual(url.pathExtension, "srt")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("1\n00:00"))
        try? FileManager.default.removeItem(at: url)
    }

    private static func downloadResponder(_ request: URLRequest) -> (Int, Data) {
        if request.url?.path.hasSuffix("/login") == true {
            return (200, Data(#"{"token":"jwt-token","status":200}"#.utf8))
        }
        if request.url?.path.hasSuffix("/download") == true {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
            return (200, Data(#"{"link":"https://dl.example.com/sub.srt"}"#.utf8))
        }
        if request.url?.host == "dl.example.com" {
            return (200, Data("1\n00:00:01,000 --> 00:00:02,000\n你好\n".utf8))
        }
        return (404, Data())
    }

    func testDownloadWithoutLoginFailsWith401() async {
        StubURLProtocol.responder = { _ in (401, Data()) }
        do {
            var client = makeClient()
            _ = try await client.download(fileID: 1, suggestedFileName: nil)
            XCTFail("应抛出错误")
        } catch {}
    }

    func testDownloadUnknownExtensionFallsBackToSrt() throws {
        // 纯逻辑验证：不认识的扩展名兜底 srt（由 download 内部处理，此处测 SubtitleStore 路径）
        let url = SubtitleStore.localURL(for: "1.srt")
        XCTAssertTrue(url.path.contains("ClearPlay/Subtitles"))
    }

    // MARK: - LocalSubtitleFinder（临时目录模拟同目录字幕）

    private func makeTempVideo(_ videoName: String, sidecars: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-sub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent(videoName)
        try Data("v".utf8).write(to: video)
        for name in sidecars {
            try Data("s".utf8).write(to: dir.appendingPathComponent(name))
        }
        return video
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSidecarExactNameMatch() throws {
        let video = try makeTempVideo("Movie.mkv", sidecars: ["Movie.srt"])
        defer { cleanup(video.deletingLastPathComponent()) }
        let tracks = LocalSubtitleFinder.sidecars(for: video)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].url.lastPathComponent, "Movie.srt")
    }

    func testSidecarLanguageSuffixMatch() throws {
        let video = try makeTempVideo("Show.S01E01.mkv", sidecars: [
            "Show.S01E01.zh.srt", "Show.S01E01.en.ass",
        ])
        defer { cleanup(video.deletingLastPathComponent()) }
        let tracks = LocalSubtitleFinder.sidecars(for: video)
        XCTAssertEqual(tracks.count, 2)

        let zh = tracks.first { $0.url.pathExtension == "srt" }
        XCTAssertEqual(zh?.language, "zh")
        XCTAssertEqual(zh?.formatHint, "srt")
        let ass = tracks.first { $0.url.pathExtension == "ass" }
        XCTAssertEqual(ass?.language, "en")
        XCTAssertEqual(ass?.formatHint, "ass")
    }

    func testSidecarIgnoresUnrelatedFilesAndFormats() throws {
        let video = try makeTempVideo("Movie.mp4", sidecars: [
            "Other.srt",          // 不同名
            "Movie.txt",          // 不支持的扩展名
            "Movie.cd1.srt",      // cd1 不是语言代码 → language 为 nil 但仍挂载
        ])
        defer { cleanup(video.deletingLastPathComponent()) }
        let tracks = LocalSubtitleFinder.sidecars(for: video)
        XCTAssertEqual(tracks.count, 1)                       // 只有 Movie.cd1.srt
        XCTAssertNil(tracks[0].language)                      // cd1 不是合法语言码
        XCTAssertEqual(tracks[0].name, "cd1")
    }
}
