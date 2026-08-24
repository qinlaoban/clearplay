import Foundation
import OSLog

/// 全局日志（Console.app 或 `log show` 可查）
let appLog = Logger(subsystem: "com.clearplay.app", category: "player")

func debugLog(_ message: String) {
    appLog.info("\(message, privacy: .public)")
    #if DEBUG
    print("[ClearPlay] \(message)")
    #endif
}
