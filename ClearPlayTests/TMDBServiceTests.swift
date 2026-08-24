import XCTest
@testable import ClearPlay_macOS

/// TMDBService 测试：URLProtocol stub 模拟 API 响应
final class TMDBServiceTests: XCTestCase {

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

    private func makeService() -> TMDBService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TMDBService(apiKey: "test-key", session: URLSession(configuration: config))
    }

    private func searchJSON(title: String, overview: String) -> Data {
        """
        {"results":[{"id":123,"title":"\(title)","overview":"\(overview)",
        "vote_average":7.8,"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg",
        "release_date":"2010-07-16"}]}
        """.data(using: .utf8)!
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - 搜索解析

    func testSearchMovieParsesFields() async throws {
        StubURLProtocol.responder = { _ in (200, self.searchJSON(title: "盗梦空间", overview: "剧情")) }
        let result = try await makeService().searchMovie(title: "Inception", year: 2010)

        XCTAssertEqual(result.tmdbID, 123)
        XCTAssertEqual(result.title, "盗梦空间")
        XCTAssertEqual(result.overview, "剧情")
        XCTAssertEqual(result.rating, 7.8)
        XCTAssertEqual(result.posterPath, "/poster.jpg")
        XCTAssertEqual(result.firstAirYear, 2010)
    }

    /// 中文查询无简介时自动回退英文简介（标题保留中文）
    func testOverviewFallsBackToEnglish() async throws {
        StubURLProtocol.responder = { request in
            let lang = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "language" }?.value
            if lang == "zh-CN" {
                return (200, self.searchJSON(title: "盗梦空间", overview: ""))
            }
            return (200, self.searchJSON(title: "Inception", overview: "A thief who steals corporate secrets."))
        }
        let result = try await makeService().searchMovie(title: "Inception", year: nil)

        XCTAssertEqual(result.title, "盗梦空间")
        XCTAssertEqual(result.overview, "A thief who steals corporate secrets.")
    }

    /// 无匹配结果抛错
    func testNoMatchThrows() async {
        StubURLProtocol.responder = { _ in (200, Data("{\"results\":[]}".utf8)) }
        do {
            _ = try await makeService().searchMovie(title: "nonexistent-movie-xyz", year: nil)
            XCTFail("应抛出 noMatch 错误")
        } catch {}
    }

    // MARK: - 图片下载

    func testDownloadImageWritesToCache() async throws {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        StubURLProtocol.responder = { _ in (200, pngData) }

        let name = try await makeService().downloadImage(
            remotePath: "/poster.jpg", cacheName: "unittest-poster"
        )
        XCTAssertEqual(name, "unittest-poster.jpg")

        let fileURL = PosterStore.localURL(for: name)
        let saved = try Data(contentsOf: fileURL)
        XCTAssertEqual(saved, pngData)
        XCTAssertTrue(PosterStore.exists(name))

        // 清理
        PosterStore.remove(name)
        XCTAssertFalse(PosterStore.exists(name))
    }

    /// 剧集搜索使用 first_air_date_year 参数与 name 字段
    func testSearchTVUsesNameField() async throws {
        StubURLProtocol.responder = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertTrue(query!.path.contains("search/tv"))
            return (200, Data("""
            {"results":[{"id":9,"name":"某剧集","overview":"简介","vote_average":8.1,
            "poster_path":"/tv.jpg","backdrop_path":null,"first_air_date":"2019-05-01"}]}
            """.utf8))
        }
        let result = try await makeService().searchTV(title: "some show", year: nil)
        XCTAssertEqual(result.tmdbID, 9)
        XCTAssertEqual(result.title, "某剧集")
        XCTAssertEqual(result.firstAirYear, 2019)
        XCTAssertNil(result.backdropPath)
    }
}
