import Foundation

/// TMDB API 客户端：搜索电影/剧集 + 下载海报与背景图
struct TMDBService {
    struct SearchResult: Sendable {
        var tmdbID: Int
        var title: String
        var overview: String?
        var rating: Double?
        var posterPath: String?      // TMDB 相对路径，如 /abc.jpg
        var backdropPath: String?
        var firstAirYear: Int?
    }

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - 搜索

    /// 电影搜索；year 用于消歧
    func searchMovie(title: String, year: Int?) async throws -> SearchResult {
        var query = [URLQueryItem(name: "query", value: title)]
        if let year { query.append(URLQueryItem(name: "year", value: String(year))) }
        return try await search(path: "search/movie", query: query)
    }

    /// 剧集搜索（剧集条目用剧名+首播年搜索）
    func searchTV(title: String, year: Int?) async throws -> SearchResult {
        var query = [URLQueryItem(name: "query", value: title)]
        if let year { query.append(URLQueryItem(name: "first_air_date_year", value: String(year))) }
        return try await search(path: "search/tv", query: query)
    }

    private func search(path: String, query: [URLQueryItem]) async throws -> SearchResult {
        let best = try await searchOnce(path: path, query: query, language: "zh-CN")
        // 中文结果缺简介时回退英文查询，标题仍优先用中文
        if (best.overview ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            let fallback = try? await searchOnce(path: path, query: query, language: "en-US")
            if let fallback, (fallback.overview ?? "").isEmpty == false {
                var merged = best
                merged.overview = fallback.overview
                if best.title.isEmpty { merged.title = fallback.title }
                return merged
            }
        }
        return best
    }

    private func searchOnce(path: String, query: [URLQueryItem], language: String) async throws -> SearchResult {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query
            + [URLQueryItem(name: "language", value: language)]

        let (data, _) = try await session.data(from: components.url!)
        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int
                // 电影字段叫 title，剧集叫 name
                let title: String?
                let name: String?
                let overview: String?
                let vote_average: Double?
                let poster_path: String?
                let backdrop_path: String?
                let release_date: String?
                let first_air_date: String?

                var displayTitle: String { title ?? name ?? "" }
                var year: Int? {
                    let s = release_date ?? first_air_date
                    guard let y = s?.prefix(4) else { return nil }
                    return Int(y)
                }
            }
            let results: [Item]
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let best = decoded.results.first else {
            throw ScrapeError.noMatch
        }
        return SearchResult(
            tmdbID: best.id,
            title: best.displayTitle,
            overview: best.overview,
            rating: best.vote_average,
            posterPath: best.poster_path,
            backdropPath: best.backdrop_path,
            firstAirYear: best.year
        )
    }

    // MARK: - 图片下载

    /// 下载 TMDB 图片到本地缓存，返回缓存文件名
    func downloadImage(remotePath: String, cacheName: String, width: Int = 500) async throws -> String {
        let url = URL(string: "https://image.tmdb.org/t/p/w\(width)\(remotePath)")!
        let (data, _) = try await session.data(from: url)
        let ext = remotePath.hasSuffix(".png") ? "png" : "jpg"
        let fileURL = PosterStore.localURL(for: "\(cacheName).\(ext)")
        try data.write(to: fileURL, options: .atomic)
        return "\(cacheName).\(ext)"
    }

    enum ScrapeError: LocalizedError {
        case noMatch
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .noMatch: return "TMDB 无匹配结果"
            case .missingAPIKey: return "未配置 TMDB API Key"
            }
        }
    }
}
