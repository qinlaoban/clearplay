import Foundation
import AetherEngine

/// 字幕本地缓存：存放在 Caches/ClearPlay/Subtitles
enum SubtitleStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ClearPlay/Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func localURL(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

/// 同目录外挂字幕发现：匹配 "视频名.srt"、"视频名.zh.srt" 等命名规则
enum LocalSubtitleFinder {
    /// 引擎支持解码的文本字幕格式
    static let supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    /// 返回可直接注册给 AetherEngine 的外挂字幕轨道列表
    static func sidecars(for videoURL: URL) -> [ExternalSubtitleTrack] {
        let base = videoURL.deletingPathExtension().lastPathComponent
        let dir = videoURL.deletingLastPathComponent()

        // 安全作用域书签播放的文件需要先启动访问权限才能列目录
        let scoped = videoURL.startAccessingSecurityScopedResource()
        defer { if scoped { videoURL.stopAccessingSecurityScopedResource() } }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        let tracks: [ExternalSubtitleTrack] = contents.compactMap { file in
            let ext = file.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { return nil }
            let stem = file.deletingPathExtension().lastPathComponent
            // 完全同名，或 "基础名.任意后缀"（如 Movie.2023.zh.srt 匹配 Movie.2023.mkv）
            guard stem == base || stem.hasPrefix(base + ".") else { return nil }
            let lang = languageCode(stem: stem, base: base)
            return ExternalSubtitleTrack(
                url: file,
                name: displayName(stem: stem, base: base, language: lang),
                language: lang,
                formatHint: ext == "ssa" ? "ass" : ext
            )
        }
        return tracks.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// 从 "Movie.2023.zh" 这类词干中提取语言代码（最后一个分段，2~3 位字母）
    private static func languageCode(stem: String, base: String) -> String? {
        guard stem != base, let last = stem.split(separator: ".").last else { return nil }
        let code = last.lowercased()
        guard (2...3).contains(code.count), code.allSatisfy(\.isLetter) else { return nil }
        // 只接受系统认识的语言代码，避免把 "cd1" 当成语言
        return Locale.current.localizedString(forIdentifier: code) != nil ? code : nil
    }

    private static func displayName(stem: String, base: String, language: String?) -> String {
        guard stem != base else { return base }
        let suffix = stem.dropFirst(base.count + 1)
        if let language, let localized = Locale.current.localizedString(forIdentifier: language) {
            return String(localized)
        }
        return String(suffix)
    }
}

/// OpenSubtitles.com REST API 客户端（搜索 + 下载）
/// 文档：https://opensubtitles.stoplight.io/docs/opensubtitles-api/
struct OpenSubtitlesClient {
    struct SearchResult: Identifiable, Sendable {
        let id: String              // subtitle_id
        let language: String        // 如 "zh"
        let releaseName: String?
        let fileName: String?
        let downloadCount: Int
        let rating: Double
        let fileID: Int?
    }

    enum SubtitleError: LocalizedError {
        case missingAPIKey
        case notLoggedIn          // /download 需要用户 JWT
        case noDownloadLink
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "未配置 OpenSubtitles API Key"
            case .notLoggedIn: return "下载字幕需要登录 OpenSubtitles 账号（设置页填写）"
            case .noDownloadLink: return "未获取到下载链接"
            case .http(let code): return "OpenSubtitles 请求失败（HTTP \(code)）"
            }
        }
    }

    private let session: URLSession
    private let apiKey: String
    private var token: String?

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - 账号

    /// 用户名/密码换取 JWT（24h 有效），下载接口必需
    mutating func login(username: String, password: String) async throws {
        struct Response: Decodable { let token: String }
        let body = ["username": username, "password": password]
        let (data, response) = try await send(path: "login", method: "POST", json: body)
        guard (200..<300).contains(response.statusCode) else { throw SubtitleError.http(response.statusCode) }
        token = try JSONDecoder().decode(Response.self, from: data).token
    }

    // MARK: - 搜索

    /// 按片名关键词搜索；剧集可传季/集号提高精度
    func search(query: String, season: Int? = nil, episode: Int? = nil,
                languages: [String] = ["zh", "en"]) async throws -> [SearchResult] {
        var items = [URLQueryItem(name: "query", value: query)]
        if !languages.isEmpty { items.append(URLQueryItem(name: "languages", value: languages.joined(separator: ","))) }
        if let season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }

        var components = URLComponents(url: Self.baseURL.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false)!
        components.queryItems = items

        let request = makeRequest(url: components.url!)
        let (data, response) = try await send(request: request)
        guard (200..<300).contains(response.statusCode) else { throw SubtitleError.http(response.statusCode) }

        struct Payload: Decodable {
            struct File: Decodable { let file_id: Int; let file_name: String? }
            struct Attributes: Decodable {
                let language: String?
                let release: String?
                let download_count: Int?
                let ratings: Double?
                let files: [File]?
            }
            struct Item: Decodable { let id: String; let attributes: Attributes }
            let data: [Item]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.data.map { item in
            SearchResult(
                id: item.id,
                language: item.attributes.language ?? "",
                releaseName: item.attributes.release,
                fileName: item.attributes.files?.first?.file_name,
                downloadCount: item.attributes.download_count ?? 0,
                rating: item.attributes.ratings ?? 0,
                fileID: item.attributes.files?.first?.file_id
            )
        }
    }

    // MARK: - 下载

    /// 用 file_id 换取临时下载链接并落盘到 SubtitleStore，返回本地文件 URL
    mutating func download(fileID: Int, suggestedFileName: String?) async throws -> URL {
        let (data, response) = try await send(path: "download", method: "POST", json: ["file_id": fileID])
        guard (200..<300).contains(response.statusCode) else { throw SubtitleError.http(response.statusCode) }

        struct Payload: Decodable { let link: String }
        let link = try JSONDecoder().decode(Payload.self, from: data).link
        guard let url = URL(string: link) else { throw SubtitleError.noDownloadLink }

        let (fileData, _) = try await session.data(from: url)

        // 扩展名优先取原始文件名，其次下载链接路径，兜底 srt
        let ext = (suggestedFileName as NSString?)?.pathExtension.lowercased()
            ?? url.pathExtension.lowercased()
        let safeExt = LocalSubtitleFinder.supportedExtensions.contains(ext) ? ext : "srt"
        let name = "\(fileID).\(safeExt)"
        let destination = SubtitleStore.localURL(for: name)
        try fileData.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - 请求构造

    private static let baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!

    private func makeRequest(url: URL, method: String = "GET", json: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("ClearPlay v0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    @discardableResult
    private func send(path: String, method: String, json: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let request = makeRequest(url: Self.baseURL.appendingPathComponent(path), method: method, json: json)
        return try await send(request: request)
    }

    private func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubtitleError.http(-1) }
        return (data, http)
    }
}

/// OpenSubtitles 账号配置读取：API Key 存 UserDefaults，密码存 Keychain
enum OpenSubtitlesAccount {
    static var apiKey: String {
        UserDefaults.standard.string(forKey: "opensubtitlesApiKey") ?? ""
    }
    static var username: String {
        KeychainStore.get("clearplay.opensubtitles.username") ?? ""
    }
    static var password: String {
        KeychainStore.get("clearplay.opensubtitles.password") ?? ""
    }

    static func setUsername(_ value: String) {
        KeychainStore.set(value.isEmpty ? nil : value, key: "clearplay.opensubtitles.username")
    }
    static func setPassword(_ value: String) {
        KeychainStore.set(value.isEmpty ? nil : value, key: "clearplay.opensubtitles.password")
    }

    /// 构造客户端；有账号时顺带登录以获得下载额度
    static func makeClient() async throws -> OpenSubtitlesClient {
        guard !apiKey.isEmpty else { throw OpenSubtitlesClient.SubtitleError.missingAPIKey }
        var client = OpenSubtitlesClient(apiKey: apiKey)
        if !username.isEmpty, !password.isEmpty {
            try? await client.login(username: username, password: password)
        }
        return client
    }
}
