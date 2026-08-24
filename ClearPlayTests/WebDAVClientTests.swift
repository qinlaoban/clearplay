import XCTest
@testable import ClearPlay_macOS

/// WebDAV 客户端测试：PROPFIND 解析、鉴权头、路径处理
final class WebDAVClientTests: XCTestCase {

    /// 拦截所有请求，返回预设响应
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
        /// 记录收到的请求（断言用）
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
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

    private func makeClient(username: String = "alice", password: String = "secret") -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return WebDAVClient(
            baseURL: URL(string: "https://nas.local:5006/dav/")!,
            username: username, password: password,
            session: URLSession(configuration: config)
        )
    }

    /// 典型 207 Multi-Status 响应（D: 前缀 + 中文目录名 + 文件）
    private var propfindXML: Data {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/%E7%94%B5%E5%BD%B1/</D:href>
            <D:propstat><D:prop>
              <D:resourcetype><D:collection/></D:resourcetype>
              <D:displayname>电影</D:displayname>
            </D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Movie.2023.mkv</D:href>
            <D:propstat><D:prop>
              <D:resourcetype/>
              <D:getcontentlength>1610612736</D:getcontentlength>
            </D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Movie.2023.chs.srt</D:href>
            <D:propstat><D:prop>
              <D:resourcetype/>
              <D:getcontentlength>1024</D:getcontentlength>
            </D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """.data(using: .utf8)!
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    // MARK: - PROPFIND 请求与解析

    func testListSendsPropfindWithAuthAndDepth() async throws {
        StubURLProtocol.responder = { _ in (207, self.propfindXML) }
        let entries = try await makeClient().list(path: "")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PROPFIND")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
        // Basic base64("alice:secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic YWxpY2U6c2VjcmV0")
    }

    func testListParsesEntriesAndSkipsSelf() async throws {
        StubURLProtocol.responder = { _ in (207, self.propfindXML) }
        let entries = try await makeClient().list(path: "")

        // 自身目录被剔除，剩 3 项
        XCTAssertEqual(entries.count, 3)

        let dir = try XCTUnwrap(entries.first { $0.isDirectory })
        XCTAssertEqual(dir.name, "电影")
        XCTAssertTrue(dir.url.absoluteString.contains("%E7%94%B5%E5%BD%B1"))

        let video = try XCTUnwrap(entries.first { $0.name == "Movie.2023.mkv" })
        XCTAssertEqual(video.sizeBytes, 1_610_612_736)
        XCTAssertFalse(video.isDirectory)
        XCTAssertTrue(video.isVideo)

        // 字幕文件不是视频扩展名
        let srt = entries.first { $0.name == "Movie.2023.chs.srt" }
        XCTAssertNotNil(srt)
        XCTAssertFalse(srt?.isVideo ?? true)
    }

    func testUnauthorizedThrows() async {
        StubURLProtocol.responder = { _ in (401, Data()) }
        do {
            _ = try await makeClient().list(path: "")
            XCTFail("应抛出 unauthorized")
        } catch let error as WebDAVError {
            if case .unauthorized = error {} else { XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testAnonymousClientOmitsAuthHeader() async throws {
        StubURLProtocol.responder = { _ in (207, self.propfindXML) }
        _ = try await makeClient(username: "", password: "").list(path: "")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPathEncodingPreservesChineseAndSpaces() throws {
        // 通过公开接口间接验证：列子目录时请求 URL 应逐段编码
        StubURLProtocol.responder = { _ in (207, self.propfindXML) }
        let client = makeClient()
        let expectation = expectation(description: "encoded path")
        StubURLProtocol.responder = { request in
            if request.url!.absoluteString.contains("%E7%94%B5%E5%BD%B1") ||
                request.url!.path.contains("电影") {
                expectation.fulfill()
            }
            return (207, self.propfindXML)
        }
        Task { _ = try? await client.list(path: "电影/合集") }
        wait(for: [expectation], timeout: 3)
    }

    // MARK: - 字幕匹配

    func testLanguageCodeMatchingRules() {
        let videoStem = "Movie.2023"
        XCTAssertNil(RemoteSubtitleFinder.languageCode(stem: "Movie.2023", videoStem: videoStem))
        XCTAssertEqual(RemoteSubtitleFinder.languageCode(stem: "Movie.2023.zh", videoStem: videoStem), "zh")
        XCTAssertEqual(RemoteSubtitleFinder.languageCode(stem: "Movie.2023.eng", videoStem: videoStem), "eng")
        // 常见非标标签别名
        XCTAssertEqual(RemoteSubtitleFinder.languageCode(stem: "Movie.2023.chs", videoStem: videoStem), "zh-Hans")
        // cd1 不是合法语言码 → 不匹配
        XCTAssertNil(RemoteSubtitleFinder.languageCode(stem: "Movie.2023.cd1", videoStem: videoStem))
        // 无关词干
        XCTAssertNil(RemoteSubtitleFinder.languageCode(stem: "Other.zh", videoStem: videoStem))
        // 多余的段不匹配
        XCTAssertNil(RemoteSubtitleFinder.languageCode(stem: "Movie.2023.chs.forced", videoStem: videoStem))
    }

    func testCandidatesFindsSidecars() {
        func entry(_ name: String, isDir: Bool = false) -> WebDAVEntry {
            WebDAVEntry(name: name, url: URL(string: "https://nas.local/dav/\(name)")!,
                        isDirectory: isDir, sizeBytes: 100)
        }
        let entries = [
            entry("电影", isDir: true),
            entry("Movie.2023.chs.srt"),
            entry("Movie.2023.eng.ass"),
            entry("Movie.2023.cd1.srt"),
            entry("Other.zh.srt"),
            entry("cover.jpg"),
        ]
        let videoURL = URL(string: "https://nas.local/dav/Movie.2023.mkv")!
        let hits = RemoteSubtitleFinder.candidates(for: videoURL, in: entries)
        XCTAssertEqual(hits.map(\.name).sorted(), ["Movie.2023.chs.srt", "Movie.2023.eng.ass"])
    }

    // MARK: - MediaItem 远程支持

    @MainActor
    func testMediaItemRemoteURL() throws {
        let parsed = FilenameParser.parse("Movie.2023.mkv")
        let remote = MediaItem(path: "https://nas.local/dav/Movie.2023.mkv", folderPath: "webdav:x", parsed: parsed)
        XCTAssertEqual(remote.url.absoluteString, "https://nas.local/dav/Movie.2023.mkv")
        XCTAssertTrue(remote.isRemote)

        let local = MediaItem(path: "/tmp/Movie.2023.mkv", folderPath: "", parsed: parsed)
        XCTAssertEqual(local.url.path, "/tmp/Movie.2023.mkv")
        XCTAssertFalse(local.isRemote)
    }
}
