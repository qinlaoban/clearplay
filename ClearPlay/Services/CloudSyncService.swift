import Foundation
import CloudKit
import CryptoKit
import SwiftData
#if os(macOS)
import Security
#endif

/// 单条续播位置更新（拉取合并的最小单元）
struct PlaybackUpdate {
    var path: String
    var position: Double
    var updatedAt: Date
}

/// CloudKit 续播同步：
/// 私有数据库 PlaybackPosition 记录（mediaPath/position/duration），
/// Mac 看一半 → 其他设备登录同一 iCloud 账号后可接着看。
/// 无 iCloud 账号 / 无权限时自动降级为不可用，不影响本地功能。
@MainActor
@Observable
final class CloudSyncService {
    static let recordType = "PlaybackPosition"
    static let containerID = "iCloud.com.clearplay.app"

    private(set) var isEnabled = false
    /// 最近一次同步错误（调试/设置页展示用）
    private(set) var lastError: String?

    private let containerID: String
    /// 惰性创建：无 entitlement 时 CKContainer(identifier:) 会直接抛 ObjC 异常
    private var container: CKContainer?
    /// 容器创建失败（异常）后不再重试
    private var containerFailed = false

    /// 待推送的更新（按 mediaPath 合并去重，延迟批量上传）
    private var pendingPushes: [String: (position: Double, duration: Double)] = [:]
    private var flushTask: Task<Void, Never>?
    /// 上次拉取时间（nil = 从未拉取，首次全量）
    private var lastPullDate: Date?

    init(containerID: String = CloudSyncService.containerID) {
        self.containerID = containerID
    }

    /// 仅在 entitlement 已配置且创建不抛异常时返回容器；否则返回 nil（同步静默禁用）。
    /// iOS 上无法可靠探测 entitlement，因此统一用 ObjC 异常捕获兜底：
    /// CKContainer(identifier:) 缺 entitlement 时抛 NSException，捕获后降级为不可用。
    private func ensureContainer() -> CKContainer? {
        if let container { return container }
        guard !containerFailed else { return nil }
        guard Self.hasICloudEntitlement(containerID: containerID) else { return nil }
        var created: CKContainer?
        let error = CPExceptionCatcher.catchException {
            created = CKContainer(identifier: self.containerID)
        }
        if let error {
            containerFailed = true
            debugLog("CKContainer init threw: \(error.localizedDescription)")
            return nil
        }
        container = created
        return created
    }

    /// 探测当前签名是否包含目标 iCloud 容器 entitlement
    nonisolated static func hasICloudEntitlement(containerID: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
        ) as? [String] else { return false }
        return value.contains(containerID)
        #else
        // iOS 上 SecTask 非公开 API；交给 ensureContainer 的异常捕获兜底降级
        true
        #endif
    }

    // MARK: - 状态检查

    /// 检查 iCloud 账号可用性；失败静默降级
    func activate() async {
        guard let container = ensureContainer() else {
            isEnabled = false
            debugLog("cloud sync disabled: no iCloud entitlement")
            return
        }
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                isEnabled = false
                debugLog("cloud sync disabled: account \(status.rawValue)")
                return
            }
            // userRecordID 需要 iCloud entitlement，未配置会抛错 → 视为不可用
            _ = try await container.userRecordID()
            isEnabled = true
            debugLog("cloud sync enabled")
        } catch {
            isEnabled = false
            lastError = error.localizedDescription
            debugLog("cloud sync unavailable: \(error)")
        }
    }

    // MARK: - 推送

    /// 记录待推送位置（10 秒空闲后批量上传，避免拖拽/频繁落盘打爆请求配额）
    func push(path: String, seconds: Double, duration: Double) {
        guard isEnabled else { return }
        pendingPushes[path] = (seconds, duration)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 立即上传全部待推送记录
    func flush() {
        guard isEnabled, !pendingPushes.isEmpty else { return }
        let batch = pendingPushes
        pendingPushes.removeAll()
        Task {
            for (path, update) in batch {
                await upload(path: path, position: update.position, duration: update.duration)
            }
        }
    }

    private func upload(path: String, position: Double, duration: Double) async {
        guard let database = ensureContainer()?.privateCloudDatabase else { return }
        let recordID = CKRecord.ID(recordName: Self.recordName(for: path))
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        let now = Date() as NSDate
        record["mediaPath"] = path as NSString
        record["position"] = position as NSNumber
        record["duration"] = duration as NSNumber
        record["updatedAt"] = now
        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 已存在：取服务端版本改字段再存
            guard let server = error.serverRecord else { return }
            server["mediaPath"] = path as NSString
            server["position"] = position as NSNumber
            server["duration"] = duration as NSNumber
            server["updatedAt"] = now
            try? await database.save(server)
        } catch {
            lastError = error.localizedDescription
            debugLog("cloud push failed: \(error)")
        }
    }

    // MARK: - 拉取

    /// 拉取自上次同步以来更新的位置并回调（首次全量）。
    /// 任一页失败即中断且不推进 lastPullDate，下次重拉同一时间窗。
    func pull(apply: @escaping ([PlaybackUpdate]) -> Void) async {
        guard isEnabled else { return }

        var all: [PlaybackUpdate] = []
        let since = lastPullDate
        let predicate = since.map {
            NSPredicate(format: "modificationDate > %@", $0 as NSDate)
        } ?? NSPredicate(value: true)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        let first = CKQueryOperation(query: query)
        first.desiredKeys = ["mediaPath", "position"]
        first.resultsLimit = 400

        var operation: CKQueryOperation? = first
        var succeeded = true
        while let op = operation {
            let (batch, cursor, ok) = await execute(op)
            all += batch
            if !ok {
                succeeded = false
                break
            }
            if let cursor {
                let next = CKQueryOperation(cursor: cursor)
                next.desiredKeys = ["mediaPath", "position"]
                next.resultsLimit = 400
                operation = next
            } else {
                operation = nil
            }
        }

        // 全部分页成功才推进水位线，避免失败丢更新
        if succeeded {
            lastPullDate = Date()
            apply(all)
        }
        debugLog("cloud pull: \(all.count) updates, ok=\(succeeded)")
    }

    /// 执行单页查询，返回本批更新、下一页游标与成败标记
    private func execute(_ operation: CKQueryOperation) async -> (batch: [PlaybackUpdate], next: CKQueryOperation.Cursor?, ok: Bool) {
        guard let database = ensureContainer()?.privateCloudDatabase else {
            return ([], nil, false)
        }
        return await withCheckedContinuation { continuation in
            var batch: [PlaybackUpdate] = []
            var nextCursor: CKQueryOperation.Cursor?
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result,
                   let update = Self.update(from: record) {
                    batch.append(update)
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    nextCursor = cursor
                    continuation.resume(returning: (batch, cursor, true))
                case .failure(let error):
                    debugLog("cloud query failed: \(error)")
                    continuation.resume(returning: (batch, nil, false))
                }
            }
            database.add(operation)
        }
    }

    /// CKRecord → PlaybackUpdate（字段缺失/类型不符返回 nil）
    nonisolated static func update(from record: CKRecord) -> PlaybackUpdate? {
        guard let path = record["mediaPath"] as? String,
              let position = record["position"] as? Double else { return nil }
        // 优先取自写 updatedAt 字段；兜底服务端 modificationDate
        guard let updated = record["updatedAt"] as? Date ?? record.modificationDate else { return nil }
        return PlaybackUpdate(path: path, position: position, updatedAt: updated)
    }

    // MARK: - 合并逻辑

    /// 把远端更新合并进本地 SwiftData：仅当远端比本地新时覆盖
    public static func apply(_ updates: [PlaybackUpdate], to context: ModelContext) {
        guard !updates.isEmpty else { return }
        for update in updates {
            guard let item = MediaQueue.find(path: update.path, context: context) else { continue }
            let localTime = item.playedAt ?? .distantPast
            guard update.updatedAt > localTime else { continue }
            item.resumeSeconds = max(0, update.position - 3) // 回退 3 秒衔接
            item.playedAt = update.updatedAt
        }
        try? context.save()
    }

    // MARK: - 记录名

    /// 路径哈希为合法且稳定的 recordName（CloudKit 要求 ≤255 字符）
    nonisolated static func recordName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
