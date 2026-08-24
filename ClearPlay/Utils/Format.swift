import Foundation

/// 秒数格式化为 mm:ss 或 h:mm:ss
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

enum Format {
    /// 影片时长展示："1 小时 52 分" / "23 分钟"
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return String(format: "%d 小时 %02d 分", minutes / 60, minutes % 60)
        }
        return "\(minutes) 分钟"
    }
}
