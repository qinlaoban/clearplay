import Foundation
import SwiftData

/// WebDAV 服务器配置（SwiftData）。密码存 Keychain（account = "webdav.<id>"）
@Model
final class WebDAVServer {
    #Unique<WebDAVServer>([\.baseURL])
    var id: UUID
    var name: String
    /// 形如 https://host:port/dav/ 的根地址
    var baseURL: String
    var username: String
    var addedAt: Date = Date()

    init(name: String, baseURL: String, username: String) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.username = username
    }

    var url: URL? {
        var str = baseURL.trimmingCharacters(in: .whitespaces)
        if !str.hasSuffix("/") { str += "/" }
        return URL(string: str)
    }

    // MARK: - 密码（Keychain）

    private var keychainAccount: String { "webdav.\(id.uuidString)" }

    var password: String {
        get { KeychainStore.get(keychainAccount) ?? "" }
        set { KeychainStore.set(newValue.isEmpty ? nil : newValue, key: keychainAccount) }
    }

    /// 删除后同时清理 Keychain 密码
    func destroy() {
        password = ""
    }
}
