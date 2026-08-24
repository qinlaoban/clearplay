import Foundation
import AetherEngine

/// WebDAV 目录条目
struct WebDAVEntry: Equatable, Sendable, Identifiable {
    /// 绝对 URL 字符串即唯一标识
    var id: String { url.absoluteString }
    /// 显示名（已百分号解码）
    var name: String
    /// 绝对 URL 字符串（可直接用于播放或再次列目录）
    var url: URL
    var isDirectory: Bool
    var sizeBytes: Int64?

    var isVideo: Bool {
        !isDirectory && FilenameParser.videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 外挂字幕候选扩展名
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
}

enum WebDAVError: LocalizedError {
    case http(Int)
    case unauthorized
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return "服务器返回 HTTP \(code)"
        case .unauthorized: return "用户名或密码错误"
        case .badResponse: return "服务器响应格式异常"
        }
    }
}

/// WebDAV 客户端：PROPFIND 列目录 + Basic 鉴权
/// 播放本身不需要该客户端——AetherEngine 直接对 http(s) URL 发 Range 请求，
/// 鉴权头通过 LoadOptions.httpHeaders 注入（见 RemoteAuthStore）
struct WebDAVClient: Sendable {
    let baseURL: URL
    let username: String
    let password: String
    var session: URLSession = .shared

    init(baseURL: URL, username: String = "", password: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    /// Basic Authorization 头值；无账号时返回 nil
    var authorizationHeader: String? {
        guard !username.isEmpty else { return nil }
        let raw = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    /// 列出 path（相对 baseURL）下的直接子项
    func list(path: String = "") async throws -> [WebDAVEntry] {
        let target = path.isEmpty ? baseURL : appending(path)
        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 20
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        // 只请求需要的属性，兼容性最好
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:"><d:prop>\
        <d:resourcetype/><d:getcontentlength/><d:displayname/>\
        </d:prop></d:propfind>
        """.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.badResponse }
        switch http.statusCode {
        case 207, 200: break // 大多数服务器返回 207 Multi-Status
        case 401, 403: throw WebDAVError.unauthorized
        default: throw WebDAVError.http(http.statusCode)
        }
        let entries = try Self.parseMultistatus(data, baseURL: baseURL)
        // 第一项是目录自身，剔除
        return entries.filter { $0.url.standardizedFileURL != target.standardizedFileURL }
    }

    /// 把相对路径拼到 baseURL（调用方传解码后的路径；此处逐段百分号编码）
    private func appending(_ path: String) -> URL {
        var base = baseURL
        if !base.absoluteString.hasSuffix("/") {
            base = URL(string: base.absoluteString + "/") ?? base
        }
        var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // 契约：调用方传解码后的路径；此处逐段百分号编码
        trimmed = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: trimmed, relativeTo: base)?.absoluteURL ?? base
    }

    // MARK: - Multi-Status XML 解析

    /// 解析 207 Multi-Status 响应（命名空间前缀不固定，按 localName 匹配）
    static func parseMultistatus(_ data: Data, baseURL: URL) throws -> [WebDAVEntry] {
        let parser = XMLParser(data: data)
        let delegate = MultistatusDelegate(baseURL: baseURL)
        parser.delegate = delegate
        guard parser.parse() else {
            throw WebDAVError.badResponse
        }
        return delegate.entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private final class MultistatusDelegate: NSObject, XMLParserDelegate {
        let baseURL: URL
        var entries: [WebDAVEntry] = []

        private var href: String?
        private var displayName: String?
        private var sizeText: String?
        private var isCollection = false
        /// 当前正在收集文本内容的属性名（href/displayname/getcontentlength）
        private var contentField: String?

        init(baseURL: URL) {
            self.baseURL = baseURL
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            let local = localName(name)
            if local == "response" {
                href = nil; displayName = nil; sizeText = nil; isCollection = false
                contentField = nil
                return
            }
            if local == "collection" {
                isCollection = true
                return
            }
            // 只关心三个带文本的属性；displayname 可能出现在 propstat 内，同样处理
            if ["href", "displayname", "getcontentlength"].contains(local) {
                contentField = local
            }
        }

        /// 文本可能分多次回调，统一追加到当前字段
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let field = contentField else { return }
            switch field {
            case "href": href = (href ?? "") + string
            case "displayname": displayName = (displayName ?? "") + string
            case "getcontentlength": sizeText = (sizeText ?? "") + string
            default: break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let local = localName(name)
            if local == "response" {
                finishEntry()
            } else if contentField == local || ["href", "displayname", "getcontentlength"].contains(local) {
                contentField = nil
            }
        }

        private func finishEntry() {
            guard let href, !href.isEmpty else { return }
            guard let url = Self.resolve(href: href, baseURL: baseURL) else { return }
            let directory = isCollection || href.hasSuffix("/")
            let name: String
            if let displayName, !displayName.isEmpty {
                name = displayName
            } else {
                let trimmed = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                name = trimmingPathComponent(decode(trimmed))
            }
            let size = sizeText.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            entries.append(WebDAVEntry(name: name, url: url, isDirectory: directory, sizeBytes: size))
        }

        private func decode(_ s: String) -> String {
            s.removingPercentEncoding ?? s
        }

        private func trimmingPathComponent(_ s: String) -> String {
            if let last = s.split(separator: "/").last { return String(last) }
            return s
        }

        private static func resolve(href: String, baseURL: URL) -> URL? {
            // href 可能是绝对路径、完整 URL 或相对路径
            if let url = URL(string: href), url.scheme != nil {
                return url
            }
            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }

        private func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }
}

extension URL {
    /// 百分号解码后的最后路径分量（WebDAV 显示名兜底用）
    var decodingLastPathComponent: String {
        lastPathComponent.removingPercentEncoding ?? lastPathComponent
    }
}

// MARK: - 播放鉴权表

/// 远程源鉴权表：内存缓存 baseURL 前缀 -> Authorization 头。
/// PlayerViewModel 加载 http(s) 源时按最长前缀匹配取头，注入 LoadOptions.httpHeaders。
@MainActor
enum RemoteAuthStore {
    private static var entries: [(prefix: String, header: String)] = []
    /// 最近一次 reload 的服务器配置（远程字幕发现需要完整客户端）
    private(set) static var servers: [WebDAVServer] = []

    /// 从服务器配置重建缓存（App 启动、增删服务器后调用）
    static func reload(servers: [WebDAVServer]) {
        self.servers = servers
        entries.removeAll()
        for server in servers {
            guard let base = server.url,
                  let client = try? makeClient(server: server),
                  let auth = client.authorizationHeader else { continue }
            entries.append((base.absoluteString, auth))
        }
        // 长前缀优先，避免 /dav 与 /dav2 之类误匹配
        entries.sort { $0.prefix.count > $1.prefix.count }
    }

    static func headers(for url: URL) -> [String: String] {
        let absolute = url.absoluteString
        guard let hit = entries.first(where: { absolute.hasPrefix($0.prefix) }) else { return [:] }
        return ["Authorization": hit.header]
    }

    static func makeClient(server: WebDAVServer) throws -> WebDAVClient {
        guard let base = server.url else { throw WebDAVError.badResponse }
        return WebDAVClient(baseURL: base, username: server.username, password: server.password)
    }
}

// MARK: - 远程外挂字幕发现

/// 从远程目录（WebDAV）里找视频的同名/同词干外挂字幕，下载到本地缓存后挂载。
/// 匹配规则与 LocalSubtitleFinder 一致：`Movie.zh.srt` 匹配 `Movie.mkv`。
enum RemoteSubtitleFinder {

    /// 常见非标字幕语言标签
    private static let languageAliases = ["chs": "zh-Hans", "cht": "zh-Hant"]

    /// 判断字幕文件名是否属于视频词干；返回语言码（可能为 nil）
    static func languageCode(stem: String, videoStem: String) -> String? {
        guard stem == videoStem else {
            // 要求形如 "<视频词干>.<语言>"：语言段须是可识别的 2~3 字母代码
            guard stem.hasPrefix(videoStem + ".") else { return nil }
            let tail = stem.dropFirst(videoStem.count + 1)
            guard !tail.isEmpty, !tail.contains("."),
                  (2...3).contains(tail.count), tail.allSatisfy(\.isLetter)
            else { return nil }
            if let alias = languageAliases[String(tail).lowercased()] { return alias }
            guard Locale.current.localizedString(forIdentifier: String(tail)) != nil
            else { return nil }
            return String(tail).lowercased()
        }
        return nil
    }

    /// 在目录条目中找出视频对应的字幕候选
    static func candidates(for videoURL: URL, in entries: [WebDAVEntry]) -> [WebDAVEntry] {
        let videoStem = videoURL.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? videoURL.deletingPathExtension().lastPathComponent
        return entries.filter { entry in
            guard !entry.isDirectory,
                  Self.subtitleExt(entry.url.pathExtension.lowercased()) != nil
            else { return false }
            let stem = entry.name.dropLast(entry.url.pathExtension.count + 1)
            return languageCode(stem: String(stem), videoStem: videoStem) != nil || stem == videoStem
        }
    }

    private static func subtitleExt(_ ext: String) -> String? {
        switch ext {
        case "srt", "vtt": return ext
        case "ssa": return "ass" // formatHint 归一
        case "ass": return "ass"
        default: return nil
        }
    }

    /// 拉取视频所在远程目录列表并下载命中的字幕到本地缓存
    static func sidecars(for videoURL: URL, client: WebDAVClient) async -> [ExternalSubtitleTrack] {
        guard videoURL.scheme == "http" || videoURL.scheme == "https" else { return [] }
        let folder = videoURL.deletingLastPathComponent()
        guard let entries = try? await client.list(path: folder.path) else { return [] }

        var tracks: [ExternalSubtitleTrack] = []
        for candidate in candidates(for: videoURL, in: entries) {
            let ext = subtitleExt(candidate.url.pathExtension.lowercased()) ?? "srt"
            // 缓存名带 URL 哈希避免不同目录同名冲突
            let cacheName = "\(abs(candidate.url.absoluteString.hashValue)).\(ext)"
            let localURL = SubtitleStore.localURL(for: cacheName)
            if !FileManager.default.fileExists(atPath: localURL.path) {
                guard await download(candidate.url, to: localURL, client: client) else { continue }
            }
            // 词干按原始扩展名剥除（.ssa 归一为 ass 后长度不同）
            let rawExtCount = candidate.url.pathExtension.count
            let stem = String(candidate.name.dropLast(rawExtCount + 1))
            let lang = languageCode(
                stem: stem,
                videoStem: videoURL.deletingPathExtension().lastPathComponent.removingPercentEncoding
                    ?? videoURL.deletingPathExtension().lastPathComponent
            )
            let displayName: String
            if let lang {
                displayName = Locale.current.localizedString(forIdentifier: lang) ?? lang
            } else {
                displayName = ext
            }
            tracks.append(ExternalSubtitleTrack(
                url: localURL, name: displayName, language: lang, formatHint: ext
            ))
        }
        return tracks
    }

    /// 带 Basic 鉴权的字幕下载（404 视为无字幕，静默跳过）
    private static func download(_ remote: URL, to local: URL, client: WebDAVClient) async -> Bool {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 20
        if let auth = client.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await client.session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200, !data.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: local, options: .atomic)
            return true
        } catch {
            debugLog("subtitle download failed: \(error)")
            return false
        }
    }
}
